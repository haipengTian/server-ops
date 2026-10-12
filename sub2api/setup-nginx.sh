#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
require_commands nginx certbot curl getent systemctl
# Enforcing 下主机 nginx 需要获准连接应用的回环端口。
if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
  require_commands getsebool
  [[ $(getsebool httpd_can_network_connect) == *'--> on' ]] ||
    die 'SELinux 尚未允许 nginx 连接应用：请执行 setsebool -P httpd_can_network_connect on 后重试'
fi
conf="/etc/nginx/conf.d/$SUB2API_DOMAIN.conf"
map=/etc/nginx/conf.d/00-sub2api-websocket-map.conf
webroot=/var/www/certbot
cert="/etc/letsencrypt/live/$SUB2API_DOMAIN/fullchain.pem"
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
render() { sed -e "s/__DOMAIN__/$SUB2API_DOMAIN/g" -e "s/__PORT__/$SUB2API_HOST_PORT/g" "$OPS_DIR/nginx/site.conf.template"; }
apply() { nginx -t; systemctl reload nginx; }
getent ahosts "$SUB2API_DOMAIN" >/dev/null || die '域名尚未解析'
mkdir -p "$webroot"
chmod 755 "$webroot"
cp "$OPS_DIR/nginx/websocket-map.conf" "$map"
chmod 644 "$map"
if [[ ! -f $cert ]]; then
  render | sed -n '1,/^}/p' > "$conf"
  chmod 644 "$conf"
  apply
  certbot certonly --webroot -w "$webroot" -d "$SUB2API_DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" --keep-until-expiring
fi
render > "$conf"
chmod 644 "$conf"
apply
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
install -m 755 "$OPS_DIR/nginx/reload-after-renew.sh" /etc/letsencrypt/renewal-hooks/deploy/sub2api-nginx-reload
# 本机验证该站点，避免经过可能配置错误的外部 CDN 或其他服务器。
curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
  --resolve "$SUB2API_DOMAIN:443:127.0.0.1" "https://$SUB2API_DOMAIN/health" >/dev/null
completed=true
printf 'HTTPS 和 nginx 已就绪：https://%s\n' "$SUB2API_DOMAIN"
