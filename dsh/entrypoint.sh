#!/bin/sh
# dsh 的 --host 只接受一个具体 IP（不接受 0.0.0.0），所以绑定容器自己的网卡地址；
# 宿主机只把它映射到 127.0.0.1，由主机 nginx 对外提供 HTTPS。
set -eu

: "${DSH_DOMAIN:?需要在 .env 中设置 DSH_DOMAIN}"

CONTAINER_IP="$(hostname -i | awk '{print $1}')"

exec dsh --profile web \
  --no-open \
  --host "$CONTAINER_IP" \
  --port 3080 \
  --public-url "https://${DSH_DOMAIN}/" \
  --trusted-host "${DSH_DOMAIN}"
