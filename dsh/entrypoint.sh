#!/bin/sh
# 0.2.0-rc.2 的网页服务只能监听 127.0.0.1（0.0.0.0 被命令行拒绝），容器外访问不到容器里的回环地址，
# 所以 dsh 监听容器内的 127.0.0.1:3080，再由 socat 把容器网卡上的 3081 转发过去；
# 宿主机只把 127.0.0.1:3080 映射到容器的 3081，由主机 nginx 对外提供 HTTPS。
# 登录靠启动令牌和签名 cookie，不看来源地址，所以转发不会绕过登录。
set -eu

: "${DSH_DOMAIN:?需要在 .env 中设置 DSH_DOMAIN}"

# dsh 拒绝加载别人可读的密钥文件；用别的工具编辑后权限常被改成 644，这里每次启动先收紧
CRED="${DSH_HOME}/.credentials.yaml"
if [ -f "$CRED" ] && ! chmod 600 "$CRED" 2>/dev/null; then
  echo "dsh-entrypoint: 无法把 $CRED 改成 600（属主不是容器用户 uid 1000），请在服务器上运行 ./setup-model.sh" >&2
fi

socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080 &

# --trusted-host：浏览器用域名访问时，/api 的 Host 校验才会放行（否则全是 403）。
# 不传 --public-url：rc.2 没有这个参数；打印的是 http://127.0.0.1:3080 开头的网址，./login-url.sh 会换成 https://<域名>。
exec dsh --profile web \
  --no-open \
  --host 127.0.0.1 \
  --port 3080 \
  --trusted-host "$DSH_DOMAIN"
