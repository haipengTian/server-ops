#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
usage() {
  cat <<'EOF'
用法：sudo bash nginx/add-site.sh --domain 域名 --upstream http://127.0.0.1:端口 --email 邮箱
可选：--upstream-server-name 证书域名   HTTPS 后端的 SNI 和证书名称
      --upstream-ca /绝对路径/ca.pem  HTTPS 后端的可信 CA
      --upstream-insecure           显式允许回环 HTTPS 后端的自签名证书
      --basic-auth-file /绝对路径/密码文件  为整个 HTTPS 入口启用 Basic Auth
域名需已指向本机，公网 TCP 80/443 需可达；先执行 nginx/install.sh。
只管理本站配置，保留请求路径，不修改代理入站、订阅服务及面板设置。
EOF
}
DOMAIN='' UPSTREAM='' EMAIL='' UPSTREAM_SERVER_NAME=''
UPSTREAM_CA=/etc/pki/tls/certs/ca-bundle.crt
UPSTREAM_INSECURE=false
CUSTOM_CA=false
BASIC_AUTH_FILE=''
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --domain|--upstream|--email|--upstream-server-name|--upstream-ca|--basic-auth-file)
      (($# >= 2)) || die "$1 缺少值"
      case "$1" in
        --domain) DOMAIN=$2 ;;
        --upstream) UPSTREAM=$2 ;;
        --email) EMAIL=$2 ;;
        --upstream-server-name) UPSTREAM_SERVER_NAME=$2 ;;
        --upstream-ca) UPSTREAM_CA=$2; CUSTOM_CA=true ;;
        --basic-auth-file) BASIC_AUTH_FILE=$2; [[ -n $BASIC_AUTH_FILE ]] || die '--basic-auth-file 不能为空' ;;
      esac
      shift 2 ;;
    --upstream-insecure) UPSTREAM_INSECURE=true; shift ;;
    *) die "未知参数：$1" ;;
  esac
done
valid_domain "$DOMAIN" || die '--domain 必须是有效的小写域名'
[[ $EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,63}$ ]] || die '--email 必须是有效邮箱'
[[ $UPSTREAM =~ ^(https?)://(127\.0\.0\.1|\[::1\]):([0-9]{1,5})/?$ ]] ||
  die '--upstream 必须是 http(s)://127.0.0.1:端口 或 http(s)://[::1]:端口，不含路径和凭据'
UPSTREAM_SCHEME=${BASH_REMATCH[1]}
UPSTREAM_HOST=${BASH_REMATCH[2]}
UPSTREAM_PORT=$((10#${BASH_REMATCH[3]}))
((UPSTREAM_PORT >= 1 && UPSTREAM_PORT <= 65535)) || die '后端端口必须在 1—65535 之间'
((UPSTREAM_PORT != 80 && UPSTREAM_PORT != 443)) || die '后端不能使用 nginx 入口端口 80/443'
UPSTREAM="$UPSTREAM_SCHEME://$UPSTREAM_HOST:$UPSTREAM_PORT"
[[ -z $UPSTREAM_SERVER_NAME ]] || valid_domain "$UPSTREAM_SERVER_NAME" || die '后端证书域名无效'
if [[ $UPSTREAM_SCHEME == http ]]; then
  [[ $UPSTREAM_INSECURE == false && $CUSTOM_CA == false && -z $UPSTREAM_SERVER_NAME ]] || die 'HTTPS 后端选项不能用于 HTTP 后端'
elif [[ $UPSTREAM_INSECURE == false ]]; then
  [[ $UPSTREAM_CA =~ ^/[a-zA-Z0-9_./-]+$ && $UPSTREAM_CA != *'..'* && -r $UPSTREAM_CA ]] || die '找不到可读的后端 CA 文件，路径不能含空格或配置字符'
else
  [[ $CUSTOM_CA == false ]] || die '--upstream-ca 和 --upstream-insecure 不能同时使用'
  printf '已显式允许跳过回环后端证书校验；公网 HTTPS 仍严格验证证书。\n' >&2
fi
SSL_NAME=${UPSTREAM_SERVER_NAME:-$UPSTREAM_HOST}
SSL_VERIFY=on
[[ $UPSTREAM_INSECURE == false ]] || SSL_VERIFY=off
if [[ -n $BASIC_AUTH_FILE ]]; then
  [[ $BASIC_AUTH_FILE =~ ^/[a-zA-Z0-9_./-]+$ && $BASIC_AUTH_FILE != *'..'* && -f $BASIC_AUTH_FILE && -r $BASIC_AUTH_FILE && -s $BASIC_AUTH_FILE ]] ||
    die '--basic-auth-file 必须是可读非空普通文件的绝对路径，不能含空格或配置字符'
fi
require_root
require_commands nginx certbot curl getent systemctl flock
[[ -d $CONF_DIR ]] || die 'nginx 配置目录不存在，请先运行 install.sh'
CONF="$CONF_DIR/$DOMAIN.conf"
require_owned "$CONF"
require_owned "$MAP_CONF"
lock_operation
systemctl is-active --quiet nginx || die 'nginx 未运行，请先运行 install.sh'
nginx -t
getent ahosts "$DOMAIN" >/dev/null || die '域名尚未解析，请先添加指向本机公网 IP 的 A/AAAA 记录'
probe_upstream

TRANSACTION=$(mktemp -d)
COMPLETED=false
HAD_CONF=false
if [[ -f $CONF ]]; then cp -p -- "$CONF" "$TRANSACTION/site.conf"; HAD_CONF=true; fi
if [[ -f $MAP_CONF ]]; then cp -p -- "$MAP_CONF" "$TRANSACTION/websocket-map.conf"; fi
restore_on_exit() {
  local status=$? file backup
  trap - EXIT INT TERM
  if [[ $COMPLETED != true ]]; then
    for file in "$CONF" "$MAP_CONF"; do
      if [[ $file == "$CONF" ]]; then backup="$TRANSACTION/site.conf"; else backup="$TRANSACTION/websocket-map.conf"; fi
      if [[ -f $backup ]]; then
        if ! cp -p -- "$backup" "$file"; then
          printf '恢复文件失败：%s；备份保留在 %s，请立即检查 nginx。\n' "$file" "$TRANSACTION" >&2
          exit 1
        fi
      elif ! rm -f -- "$file"; then
        printf '清理本次配置失败：%s；事务目录：%s\n' "$file" "$TRANSACTION" >&2
        exit 1
      fi
    done
    if ! apply_nginx; then
      printf '本站配置已还原，但恢复后的 nginx 检查或重载失败；备份保留在 %s。\n' "$TRANSACTION" >&2
      exit 1
    fi
    printf '本站配置未完成，已恢复原站点；已签发的证书保留，可修复原因后重试。\n' >&2
  fi
  rm -rf -- "$TRANSACTION"
  exit "$status"
}
trap restore_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
install -d -m 755 "$WEBROOT"
# 所有站点使用相同的 Upgrade 映射，短变量适配默认 64 字节哈希桶。
# 接入入口也安装它，升级脚本后无需重新执行主机安装。
install -m 644 "$OPS_DIR/templates/websocket-map.conf" "$MAP_CONF"
if [[ $HAD_CONF == false || ! -s $CERT_DIR/$DOMAIN/fullchain.pem || ! -s $CERT_DIR/$DOMAIN/privkey.pem ]]; then
  # 临时站点只提供 ACME 验证，避免签发前暴露明文管理页面。
  render http.conf.template > "$TRANSACTION/new.conf"
  install -m 644 "$TRANSACTION/new.conf" "$CONF"
  apply_nginx
fi
certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --cert-name "$DOMAIN" \
  --non-interactive --agree-tos --email "$EMAIL" --keep-until-expiring
[[ -s $CERT_DIR/$DOMAIN/fullchain.pem && -s $CERT_DIR/$DOMAIN/privkey.pem ]] || die '证书签发命令结束，但完整证书或私钥缺失'
render site.conf.template > "$TRANSACTION/new.conf"
if [[ $UPSTREAM_SCHEME == http ]]; then
  sed -i '/# BEGIN UPSTREAM TLS/,/# END UPSTREAM TLS/d' "$TRANSACTION/new.conf"
fi
install -m 644 "$TRANSACTION/new.conf" "$CONF"
apply_nginx
wait_https
COMPLETED=true
printf 'HTTPS 已就绪：https://%s/\n' "$DOMAIN"
printf '使用原来的登录路径访问。请在电脑浏览器验证证书、登录和业务功能。\n'
