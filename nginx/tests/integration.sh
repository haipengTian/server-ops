#!/usr/bin/env bash
# 真实 nginx + 临时证书：所有监听和文件均在本机沙箱，不调用 systemctl/dnf/Certbot。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"
NGINX_BIN=${1:-nginx}
require_commands "$NGINX_BIN" curl openssl python3
TEST_ROOT=$(mktemp -d /tmp/server-ops-nginx-integration-XXXXXXXX)
NGINX_PID=''
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $NGINX_PID ]]; then kill "$NGINX_PID" 2>/dev/null || true; wait "$NGINX_PID" 2>/dev/null || true; fi
  if ((status != 0)); then cat "$TEST_ROOT/error.log" >&2; fi
  rm -rf -- "$TEST_ROOT"
  exit "$status"
}
trap cleanup EXIT
chmod 755 "$TEST_ROOT"
mkdir -p "$TEST_ROOT/conf.d" "$TEST_ROOT/cert" "$TEST_ROOT/webroot/.well-known/acme-challenge"
printf acme-token > "$TEST_ROOT/webroot/.well-known/acme-challenge/probe"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=vpn.thpvip.xyz' \
  -addext 'subjectAltName=DNS:vpn.thpvip.xyz,DNS:app.thpvip.xyz' \
  -keyout "$TEST_ROOT/cert/privkey.pem" -out "$TEST_ROOT/cert/fullchain.pem" >/dev/null 2>&1
# 让系统分配临时端口，避免占用本机实际服务的 80/443。
ports=$(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(4)]
for sock in sockets:
    sock.bind(('127.0.0.1', 0))
print(*(sock.getsockname()[1] for sock in sockets))
for sock in sockets:
    sock.close()
PY
)
read -r HTTP_PORT HTTPS_PORT BACKEND_HTTP_PORT BACKEND_HTTPS_PORT <<< "$ports"
render_site() {
  DOMAIN=$1
  UPSTREAM=$2
  CONNECTION_VAR="integration_${DOMAIN%%.*}_connection_upgrade"
  SSL_NAME=vpn.thpvip.xyz
  SSL_VERIFY=on
  UPSTREAM_CA="$TEST_ROOT/cert/fullchain.pem"
  render site.conf.template | sed \
    -e "s|listen 80;|listen 127.0.0.1:$HTTP_PORT;|" \
    -e "s|listen 443 ssl;|listen 127.0.0.1:$HTTPS_PORT ssl;|" \
    -e '/listen \[::\]/d' \
    -e "s|/etc/letsencrypt/live/$DOMAIN|$TEST_ROOT/cert|g" \
    -e "s|/var/www/certbot|$TEST_ROOT/webroot|g" > "$TEST_ROOT/conf.d/$DOMAIN.conf"
  if [[ $UPSTREAM == http://* ]]; then sed -i '/# BEGIN UPSTREAM TLS/,/# END UPSTREAM TLS/d' "$TEST_ROOT/conf.d/$DOMAIN.conf"; fi
}
render_site vpn.thpvip.xyz "http://127.0.0.1:$BACKEND_HTTP_PORT"
render_site app.thpvip.xyz "https://127.0.0.1:$BACKEND_HTTPS_PORT"
cat > "$TEST_ROOT/nginx.conf" <<EOF
worker_processes 1;
pid $TEST_ROOT/nginx.pid;
error_log $TEST_ROOT/error.log;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $TEST_ROOT/body;
    proxy_temp_path $TEST_ROOT/proxy;
    fastcgi_temp_path $TEST_ROOT/fastcgi;
    uwsgi_temp_path $TEST_ROOT/uwsgi;
    scgi_temp_path $TEST_ROOT/scgi;
    server {
        listen 127.0.0.1:$BACKEND_HTTP_PORT;
        location = / { return 404; }
        location = /panel/login/ { return 200 'panel-login'; }
        location = /headers { return 200 "\$http_x_forwarded_for|\$http_x_real_ip"; }
    }
    server {
        listen 127.0.0.1:$BACKEND_HTTPS_PORT ssl;
        ssl_certificate $TEST_ROOT/cert/fullchain.pem;
        ssl_certificate_key $TEST_ROOT/cert/privkey.pem;
        location / { return 200 'tls-backend'; }
    }
    include $TEST_ROOT/conf.d/*.conf;
}
EOF
"$NGINX_BIN" -p "$TEST_ROOT/" -c "$TEST_ROOT/nginx.conf" -e "$TEST_ROOT/error.log" -t
"$NGINX_BIN" -p "$TEST_ROOT/" -c "$TEST_ROOT/nginx.conf" -e "$TEST_ROOT/error.log" -g 'daemon off;' &
NGINX_PID=$!
client() {
  local domain=$1; shift
  curl --silent --show-error --noproxy '*' --max-time 5 --cacert "$TEST_ROOT/cert/fullchain.pem" \
    --resolve "$domain:$HTTPS_PORT:127.0.0.1" "$@"
}
ready=false
for attempt in {1..30}; do
  if client vpn.thpvip.xyz "https://vpn.thpvip.xyz:$HTTPS_PORT/panel/login/" > "$TEST_ROOT/response" 2>/dev/null; then ready=true; break; fi
  sleep 0.1
done
[[ $ready == true && $(cat "$TEST_ROOT/response") == panel-login ]] || die '真实 nginx 没有保留面板路径'
echo 'PASS: 真实 nginx 校验证书并保留面板登录路径'
[[ $(client app.thpvip.xyz "https://app.thpvip.xyz:$HTTPS_PORT/") == tls-backend ]] || die 'HTTPS 后端证书或代理失败'
echo 'PASS: 同一 HTTPS 入口按域名分发，HTTPS 后端严格验证证书和 SNI'
[[ $(client vpn.thpvip.xyz -H 'X-Forwarded-For: 192.0.2.99' -H 'X-Real-IP: 192.0.2.99' "https://vpn.thpvip.xyz:$HTTPS_PORT/headers") == '127.0.0.1|127.0.0.1' ]] || die '客户端伪造 IP 未被覆盖'
echo 'PASS: 真实请求覆盖伪造的客户端 IP 头'
[[ $(curl --silent --show-error --noproxy '*' --max-time 5 --resolve "vpn.thpvip.xyz:$HTTP_PORT:127.0.0.1" "http://vpn.thpvip.xyz:$HTTP_PORT/.well-known/acme-challenge/probe") == acme-token ]] || die 'ACME webroot 不可达'
[[ $(curl --silent --show-error --noproxy '*' --max-time 5 --resolve "vpn.thpvip.xyz:$HTTP_PORT:127.0.0.1" --output /dev/null --write-out '%{http_code}' "http://vpn.thpvip.xyz:$HTTP_PORT/panel/login/") == 301 ]] || die 'HTTP 没有跳转 HTTPS'
echo 'PASS: HTTP 保留 ACME 验证路径，应用访问跳转 HTTPS'
cat > "$TEST_ROOT/conf.d/00-duplicate.conf" <<EOF
server {
    listen 127.0.0.1:$HTTP_PORT;
    server_name vpn.thpvip.xyz;
    return 200;
}
EOF
if (
  DOMAIN=vpn.thpvip.xyz
  nginx() { "$NGINX_BIN" -p "$TEST_ROOT/" -c "$TEST_ROOT/nginx.conf" -e "$TEST_ROOT/error.log" "$@"; }
  systemctl() { touch "$TEST_ROOT/unexpected-reload"; }
  apply_nginx
) > "$TEST_ROOT/conflict-output" 2>&1; then die '真实 nginx 的域名冲突未阻止发布'; fi
[[ ! -e $TEST_ROOT/unexpected-reload ]] || die '域名冲突后仍然重载 nginx'
grep -q '当前域名在其他监听配置中冲突' "$TEST_ROOT/conflict-output" || die '没有识别真实 nginx 的冲突警告'
echo 'PASS: 真实 nginx 虽允许同域名冲突，发布入口仍明确停止且不重载'
echo 'All real nginx integration checks passed.'
