#!/usr/bin/env bash
# 第 2 步：为 DSH_DOMAIN 配置主机 nginx 站点并签发证书（certbot webroot，与本机其他站点一致）
# 每次改动后都先 nginx -t；检查失败会恢复原文件，不会留下让 nginx 无法重载的坏配置
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
load_env
for cmd in nginx certbot curl getent; do
  command -v "$cmd" >/dev/null || { echo "没有找到 $cmd" >&2; exit 1; }
done

DOMAIN="${DSH_DOMAIN}"
CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
MAP="/etc/nginx/conf.d/00-websocket-upgrade-map.conf"
WEBROOT="/var/www/certbot"
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
BACKUP_DIR="$(mktemp -d)"

render() {
  sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__PORT__/${DSH_HOST_PORT}/g" nginx/dsh.conf.template
}

# 备份即将改动的文件，nginx -t 失败时恢复
for f in "$CONF" "$MAP"; do
  if [ -f "$f" ]; then cp -p "$f" "$BACKUP_DIR/"; fi
done

restore() {
  echo "❌ nginx 配置检查失败，已恢复原状" >&2
  for f in "$CONF" "$MAP"; do
    if [ -f "$BACKUP_DIR/$(basename "$f")" ]; then
      cp -p "$BACKUP_DIR/$(basename "$f")" "$f"
    else
      rm -f "$f"
    fi
  done
  exit 1
}

apply() {
  local out
  if ! out="$(nginx -t 2>&1)"; then
    echo "$out" >&2
    restore
  fi
  systemctl reload nginx
}

resolved="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')"
if [ -z "$resolved" ]; then
  echo "❌ ${DOMAIN} 还没有 DNS 解析，先在域名服务商加 A 记录指向本服务器" >&2
  exit 1
fi
echo "== ${DOMAIN} 解析到 ${resolved}"

# WebSocket 升级映射是 http 级别的，整台机器只能定义一次
if ! nginx -T 2>/dev/null | grep -qE 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade'; then
  echo "== 安装 WebSocket 升级映射"
  cp nginx/websocket-map.conf "$MAP"
fi

if [ ! -f "$CERT" ]; then
  echo "== 先只装 80 端口那段，用于证书验证"
  render | sed -n '1,/^}/p' > "$CONF"
  apply
  mkdir -p "$WEBROOT"
  echo "== 签发证书（续期由 certbot 自带的定时任务负责）"
  if ! certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --keep-until-expiring; then
    echo "❌ 证书签发失败。80 端口段已保留（不影响其他站点），确认 DNS 指向本机后可以重跑本脚本" >&2
    exit 1
  fi
fi

echo "== 安装完整站点配置"
render > "$CONF"
apply

sleep 2
code="$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || true)"
echo "✅ https://${DOMAIN}/ → HTTP ${code}（未登录返回 401 属正常）"
echo "下一步：./login-url.sh"
