#!/usr/bin/env bash
# 第 3 步：打印 dsh 启动时生成的登录网址（带启动令牌）。
# 这个网址等同于密码：只在自己的浏览器里打开，不要发给别人、不要贴到任何聊天里。
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

load_env

# dsh 启动时打印一行「dsh web: <带令牌的网址> (LAN: ...)」。取最后一次启动的那一行里的第一个网址；
# 它是容器内部地址，把「协议://主机:端口」换成对外域名，路径和令牌原样保留。
line="$(docker compose logs --no-log-prefix dsh 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -F 'dsh web: http' \
  | tail -1 || true)"
raw="$(printf '%s' "$line" | grep -oE "https?://[^[:space:]\"'<>()]+" | head -1 || true)"

if [ -z "$raw" ]; then
  echo "没有在日志里找到登录网址。最近的日志：" >&2
  docker compose logs --tail 30 dsh >&2
  exit 1
fi

url="$(printf '%s' "$raw" | sed -E "s|^https?://[^/?#]+|https://${DSH_DOMAIN}|")"

echo "在浏览器里打开下面的网址登录（只需打开一次，之后浏览器会记住会话）："
echo
echo "  $url"
echo
echo "⚠️  这个网址等同于密码，不要分享。容器重启后会生成新的网址。"
