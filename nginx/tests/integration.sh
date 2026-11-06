#!/usr/bin/env bash
# 真实 nginx + 临时证书：所有监听和文件均在本机沙箱，不调用 systemctl/dnf/Certbot。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"
NGINX_BIN=${1:-nginx}
require_commands "$NGINX_BIN" curl openssl python3
# 后面的冲突测试会定义 nginx 包装函数，先固定外部可执行文件，避免命令名递归。
NGINX_BIN=$(command -v -- "$NGINX_BIN")
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
  -addext 'subjectAltName=DNS:vpn.thpvip.xyz,DNS:app.thpvip.xyz,DNS:qqdesk.thpvip.xyz' \
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
# 仅供隔离测试的凭据；运行时密码由用户在服务器通过 htpasswd 输入。
printf 'fixture:%s\n' "$(openssl passwd -apr1 'fixture-only')" > "$TEST_ROOT/passwords"
chmod 644 "$TEST_ROOT/passwords"
BASIC_AUTH_FILE="$TEST_ROOT/passwords"
render_site qqdesk.thpvip.xyz "http://127.0.0.1:$BACKEND_HTTP_PORT"
unset BASIC_AUTH_FILE
cp "$ROOT/templates/websocket-map.conf" "$TEST_ROOT/conf.d/00-server-ops-websocket-map.conf"
cat > "$TEST_ROOT/nginx.conf" <<EOF
worker_processes 1;
pid $TEST_ROOT/nginx.pid;
error_log $TEST_ROOT/error.log;
events { worker_connections 64; }
http {
    access_log off;
    variables_hash_bucket_size 64;
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
        location = /authorization { return 200 "auth=\$http_authorization"; }
        location = /websockify {
            if (\$http_upgrade != websocket) { return 400; }
            if (\$http_connection != upgrade) { return 400; }
            add_header Upgrade websocket always;
            add_header Connection upgrade always;
            return 101;
        }
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
for path in /panel/login/ /websockify; do
  for credentials in '' 'fixture:wrong'; do
    auth_args=()
    if [[ -n $credentials ]]; then auth_args=(-u "$credentials"); fi
    [[ $(client qqdesk.thpvip.xyz "${auth_args[@]}" --output /dev/null --write-out '%{http_code}' "https://qqdesk.thpvip.xyz:$HTTPS_PORT$path") == 401 ]] || die '桌面页面或 WebSocket 路径未阻挡匿名/错误密码'
  done
done
[[ $(client qqdesk.thpvip.xyz -u fixture:fixture-only "https://qqdesk.thpvip.xyz:$HTTPS_PORT/panel/login/") == panel-login ]] || die '正确密码不能打开受保护页面'
[[ $(client qqdesk.thpvip.xyz -u fixture:fixture-only "https://qqdesk.thpvip.xyz:$HTTPS_PORT/authorization") == auth= ]] || die '网关认证凭据泄露给后端'
[[ $(client vpn.thpvip.xyz -H 'Authorization: Bearer fixture' "https://vpn.thpvip.xyz:$HTTPS_PORT/authorization") == 'auth=Bearer fixture' ]] || die '未启用 Basic Auth 的后端认证被破坏'
[[ $(curl --silent --show-error --noproxy '*' --max-time 5 --resolve "qqdesk.thpvip.xyz:$HTTP_PORT:127.0.0.1" "http://qqdesk.thpvip.xyz:$HTTP_PORT/.well-known/acme-challenge/probe") == acme-token ]] || die '认证阻止 ACME 续期'
python3 - "$HTTPS_PORT" "$TEST_ROOT/cert/fullchain.pem" <<'PY'
import base64
import socket
import ssl
import sys

context = ssl.create_default_context(cafile=sys.argv[2])
with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=5) as tcp:
    with context.wrap_socket(tcp, server_hostname='qqdesk.thpvip.xyz') as client:
        token = base64.b64encode(b'fixture:fixture-only').decode()
        client.sendall((
            'GET /websockify HTTP/1.1\r\nHost: qqdesk.thpvip.xyz\r\n'
            'Upgrade: websocket\r\nConnection: Upgrade\r\n'
            f'Authorization: Basic {token}\r\n\r\n'
        ).encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = client.recv(4096)
            if not chunk:
                raise SystemExit('WebSocket handshake closed early')
            response += chunk
        assert response.startswith(b'HTTP/1.1 101 '), response
PY
echo 'PASS: Basic Auth 阻挡匿名和错误密码，正确密码可访问和升级 WebSocket，凭据不进入后端且 ACME 不受影响'
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
