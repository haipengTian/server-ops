#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
require_commands nginx certbot curl getent systemctl sleep
[[ $CERTBOT_EMAIL =~ ^[^@]+@[^@]+\.[^@]+$ ]] || die '请填写 .env 中的 CERTBOT_EMAIL'
# Verify persisted configuration and authentication before publishing the site.
verify_http
nginx_version=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
[[ -n $nginx_version && $(printf '%s\n' 1.25.1 "$nginx_version" | sort -V | head -n1) == 1.25.1 ]] || die '当前模板需要 nginx >= 1.25.1'
# Enforcing 下主机 nginx 需要获准连接应用的回环端口。
if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
  require_commands getsebool
  [[ $(getsebool httpd_can_network_connect) == *'--> on' ]] ||
    die 'SELinux 尚未允许 nginx 连接应用：请执行 setsebool -P httpd_can_network_connect on 后重试'
fi
conf="/etc/nginx/conf.d/$CLIPROXY_DOMAIN.conf"
map=/etc/nginx/conf.d/00-cliproxyapi-websocket-map.conf
webroot=/var/www/certbot
cert="/etc/letsencrypt/live/$CLIPROXY_DOMAIN/fullchain.pem"
saved=$(mktemp -d)
for file in "$conf" "$map"; do
  [[ ! -f $file ]] || cp -p -- "$file" "$saved/$(basename "$file")"
done
completed=false
restore_on_exit() {
  local status=$? file
  trap - EXIT
  if [[ $completed != true ]]; then
    for file in "$conf" "$map"; do
      if [[ -f $saved/$(basename "$file") ]]; then
        cp -p -- "$saved/$(basename "$file")" "$file"
      else
        rm -f -- "$file"
      fi
    done
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx || status=1; fi
    printf '站点配置未完成，已恢复本次修改的 nginx 配置。\n' >&2
  fi
  rm -rf -- "$saved"
  exit "$status"
}
trap restore_on_exit EXIT
render() { sed -e "s/__DOMAIN__/$CLIPROXY_DOMAIN/g" -e "s/__PORT__/$CLIPROXY_HOST_PORT/g" "$OPS_DIR/nginx/site.conf.template"; }
apply() { nginx -t; systemctl reload nginx; }
getent ahosts "$CLIPROXY_DOMAIN" >/dev/null || die '域名尚未解析'
mkdir -p "$webroot"
chmod 755 "$webroot"
cp "$OPS_DIR/nginx/websocket-map.conf" "$map"
chmod 644 "$map"
if [[ ! -f $cert ]]; then
  render | sed -n '1,/^}/p' > "$conf"
  chmod 644 "$conf"
  apply
  certbot certonly --webroot -w "$webroot" -d "$CLIPROXY_DOMAIN" --non-interactive --agree-tos --email "$CERTBOT_EMAIL" --keep-until-expiring
fi
render > "$conf"
chmod 644 "$conf"
apply
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
install -m 755 "$OPS_DIR/nginx/reload-after-renew.sh" /etc/letsencrypt/renewal-hooks/deploy/cliproxyapi-nginx-reload
# reload 返回时新 worker 可能尚未接管；用实际 HTTPS 等待，保留完整证书校验。
# --noproxy 确保本机检查不会被服务器上的代理环境变量转发。
wait_https() {
  local attempt
  for attempt in {1..10}; do
    if curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
      --resolve "$CLIPROXY_DOMAIN:443:127.0.0.1" "https://$CLIPROXY_DOMAIN/management.html" \
      > /dev/null 2> "$saved/https-error"; then
      return 0
    fi
    [[ $attempt == 10 ]] || sleep 1
  done
  cat "$saved/https-error" >&2
  die 'nginx 重载后 HTTPS 校验仍失败，请核对证书域名、站点监听和 nginx 错误日志'
}
wait_https
code=$(curl --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
  --resolve "$CLIPROXY_DOMAIN:443:127.0.0.1" "https://$CLIPROXY_DOMAIN/v1/models")
[[ $code == 401 ]] || die "HTTPS 认证检查失败：/v1/models 返回 $code"
completed=true
printf 'HTTPS 和 nginx 已就绪：https://%s\n' "$CLIPROXY_DOMAIN"
