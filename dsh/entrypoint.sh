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

# dsh 的写锁（<文件>.lock，内容是持有者 PID）只在该 PID 不存在时才会被接管。容器里每次启动 dsh 的 PID 都一样，
# 上一次启动失败时留下的锁会被当成「仍被持有」，之后 dsh plugin 等写操作一直等到超时。
# 这里是容器刚启动、dsh 还没运行，不可能有真正的持有者，所以清掉残留的锁。
find "$DSH_HOME" -name node_modules -prune -o -type f -name '*.lock' -print 2>/dev/null | while IFS= read -r lock; do
  if [ "$(wc -l < "$lock")" -le 1 ] && grep -qxE '[0-9]+' "$lock"; then
    rm -f "$lock" && echo "dsh-entrypoint: 清除上次残留的写锁 $lock" >&2
  fi
done

socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080 &

# --trusted-host：浏览器用域名访问时，/api 的 Host 校验才会放行（否则全是 403）。
# 不传 --public-url：rc.2 没有这个参数；打印的是 http://127.0.0.1:3080 开头的网址，./login-url.sh 会换成 https://<域名>。
exec dsh --profile web \
  --no-open \
  --host 127.0.0.1 \
  --port 3080 \
  --trusted-host "$DSH_DOMAIN"
