#!/bin/sh
# dsh 的 --host 只接受一个具体 IP（不接受 0.0.0.0），所以绑定容器自己的网卡地址；
# 宿主机只把它映射到 127.0.0.1，由主机 nginx 对外提供 HTTPS。
set -eu

: "${DSH_DOMAIN:?需要在 .env 中设置 DSH_DOMAIN}"

CONTAINER_IP="$(hostname -i | awk '{print $1}')"

# --trusted-host：浏览器用域名访问时，/api 的 Host 校验才会放行（否则全是 403）。
# 不传 --public-url：0.2.0-rc.2 没有这个参数，它也只影响打印出来的网址；
# 打印的是容器内部地址，./login-url.sh 会换成 https://<域名>。
exec dsh --profile web \
  --no-open \
  --host "$CONTAINER_IP" \
  --port 3080 \
  --trusted-host "$DSH_DOMAIN"
