#!/usr/bin/env bash
# 运行真实入口；只模拟包管理、服务、网络和证书签发，文件事务为真实操作。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_NGINX_BIN=${1:-}
if [[ -n $TEST_NGINX_BIN ]]; then TEST_NGINX_BIN=$(command -v -- "$TEST_NGINX_BIN"); fi
export TEST_NGINX_BIN
TEST_ROOT=$(mktemp -d /tmp/server-ops-nginx-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${SIM:-}/output ]] || cat "$SIM/output" >&2; exit 1; }
[[ -f $ROOT/install.sh && -f $ROOT/add-site.sh ]] || fail '缺少公共 nginx 安装和站点接入入口'
mkdir "$TEST_ROOT/bin"
if [[ -n $TEST_NGINX_BIN ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=vpn.thpvip.xyz' \
    -keyout "$TEST_ROOT/privkey.pem" -out "$TEST_ROOT/fullchain.pem" >/dev/null 2>&1
fi
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 0
MOCK
cat > "$TEST_ROOT/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
echo "nginx $*" >> "$SIM/events"
if [[ $MODE == actual-nginx ]]; then
  exec "$TEST_NGINX_BIN" -p "$SIM/" -c "$SIM/nginx.conf" -e "$SIM/error.log" "$@"
fi
if [[ $MODE == duplicate-name && -f $SIM/etc/nginx/conf.d/vpn.thpvip.xyz.conf ]]; then
  echo 'nginx: [warn] conflicting server name "vpn.thpvip.xyz" on 0.0.0.0:80, ignored' >&2
fi
[[ $MODE != syntax-failure ]]
MOCK
cat > "$TEST_ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SIM/events"
case "$1" in
  is-active) [[ ${*: -1} != firewalld || $MODE != inactive-firewall ]] ;;
  cat) [[ $MODE != missing-timer && ${*: -1} == certbot-renew.timer ]] ;;
  reload)
    n=$(cat "$SIM/reloads"); n=$((n + 1)); echo "$n" > "$SIM/reloads"
    [[ $MODE != reload-failure || $n != 2 ]] ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo "curl $*" >> "$SIM/events"
[[ " $* " == *' --noproxy * '* ]] || exit 92
url=${*: -1}
if [[ $url == https://vpn.thpvip.xyz/* ]]; then
  [[ " $* " != *' --insecure '* && " $* " != *' -k '* ]] || exit 93
  n=$(cat "$SIM/attempts"); n=$((n + 1)); echo "$n" > "$SIM/attempts"
  if [[ $MODE == wrong-cert || $MODE == delayed && $n -le 3 ]]; then exit 60; fi
  if [[ $MODE == bad-gateway ]]; then echo 502; else echo 404; fi
else
  [[ $MODE != wrong-protocol ]] || exit 1
  if [[ $MODE == upstream-tls && " $* " != *' --insecure '* ]]; then exit 60; fi
  echo 404
fi
MOCK
cat > "$TEST_ROOT/bin/getent" <<'MOCK'
#!/usr/bin/env bash
[[ $MODE != no-dns ]] || exit 2
echo '192.0.2.1 STREAM vpn.thpvip.xyz'
MOCK
cat > "$TEST_ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
echo "certbot $*" >> "$SIM/events"
[[ $MODE != cert-failure ]] || exit 1
dir="$SIM/etc/letsencrypt/live/vpn.thpvip.xyz"
mkdir -p "$dir"
if [[ $MODE == actual-nginx ]]; then
  cp "$SIM/../fullchain.pem" "$dir/fullchain.pem"
  cp "$SIM/../privkey.pem" "$dir/privkey.pem"
  exit 0
fi
echo certificate > "$dir/fullchain.pem"
echo private-key > "$dir/privkey.pem"
MOCK
cat > "$TEST_ROOT/bin/dnf" <<'MOCK'
#!/usr/bin/env bash
echo "dnf $*" >> "$SIM/events"
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ $MODE == occupied-port ]]; then echo 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=1,fd=1))'; fi
MOCK
cat > "$TEST_ROOT/bin/getenforce" <<'MOCK'
#!/usr/bin/env bash
echo Enforcing
MOCK
cat > "$TEST_ROOT/bin/setsebool" <<'MOCK'
#!/usr/bin/env bash
echo "setsebool $*" >> "$SIM/events"
MOCK
cat > "$TEST_ROOT/bin/firewall-cmd" <<'MOCK'
#!/usr/bin/env bash
echo "firewall-cmd $*" >> "$SIM/events"
case "$*" in
  --get-active-zones) printf 'external\n  interfaces: eth0\n' ;;
  *--query-service=*) exit 1 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
count=0
fixture() {
  count=$((count + 1)); export SIM="$TEST_ROOT/case$count" MODE=$1
  OPS="$SIM/ops"
  mkdir -p "$OPS" "$SIM/etc/nginx/conf.d" "$SIM/etc/pki/tls/certs" "$SIM/run/lock"
  cp "$ROOT/"*.sh "$OPS/"
  cp -R "$ROOT/templates" "$OPS/"
  # 与仓库现有部署测试一致，固定系统路径仅在副本里替换。
  sed -i "s|/etc/|$SIM/etc/|g;s|/var/|$SIM/var/|g;s|/run/lock/|$SIM/run/lock/|g" "$OPS/"*.sh "$OPS/templates/"*
  printf 'ID=centos\nVERSION_ID=9\n' > "$SIM/etc/os-release"
  echo fixture-ca > "$SIM/etc/pki/tls/certs/ca-bundle.crt"
  echo 0 > "$SIM/attempts"; echo 0 > "$SIM/reloads"; : > "$SIM/events"
  CONF="$SIM/etc/nginx/conf.d/vpn.thpvip.xyz.conf"
  MAP="$SIM/etc/nginx/conf.d/00-server-ops-websocket-map.conf"
  echo unrelated-site > "$SIM/etc/nginx/conf.d/other.example.com.conf"
}
site() { bash "$OPS/add-site.sh" --domain vpn.thpvip.xyz --upstream http://127.0.0.1:8888 --email fixture@example.com "$@"; }
run_ok() { "$@" > "$SIM/output" 2>&1 || fail '入口执行失败'; }
run_fail() { if "$@" > "$SIM/output" 2>&1; then fail '应拒绝的操作却成功'; fi; }
unchanged_other() { [[ $(cat "$SIM/etc/nginx/conf.d/other.example.com.conf") == unrelated-site ]] || fail '修改了其他站点'; }

fixture delayed
run_ok site
[[ $(cat "$SIM/attempts") == 4 ]] || fail '没有等待 nginx 新 worker 生效'
grep -q 'proxy_pass http://127.0.0.1:8888;' "$CONF" || fail '后端地址错误'
# shellcheck disable=SC2016
grep -q 'X-Forwarded-For $remote_addr;' "$CONF" || fail '未覆盖客户端伪造来源'
grep -q 'certonly --webroot' "$SIM/events" || fail '未用 webroot 签发证书'
grep -q -- '--cert-name vpn.thpvip.xyz' "$SIM/events" || fail '证书名称不确定'
unchanged_other
echo 'PASS: webroot 签发、保留路径、可信转发头，等待 TLS 就绪并接受面板根路径 404'

fixture normal
run_ok site
cp "$CONF" "$SIM/first-site"
run_ok site
cmp -s "$CONF" "$SIM/first-site" || fail '重复接入产生不同配置'
echo 'PASS: 重复接入同一站点保持配置稳定'

fixture normal
echo unmanaged-site > "$CONF"
run_fail site
[[ $(cat "$CONF") == unmanaged-site && ! -s $SIM/events ]] || fail '覆盖了非本工具管理的站点'
echo 'PASS: 拒绝覆盖已有其他部署入口管理的站点'

fixture normal
echo unmanaged-map > "$MAP"
run_fail site
[[ $(cat "$MAP") == unmanaged-map && ! -e $CONF && ! -s $SIM/events ]] || fail '覆盖了其他入口管理的 map'
echo 'PASS: 拒绝覆盖未由本工具管理的共用 map'

fixture duplicate-name
echo existing-vpn-site > "$SIM/etc/nginx/conf.d/00-existing.conf"
run_fail site
[[ ! -e $CONF && $(cat "$SIM/etc/nginx/conf.d/00-existing.conf") == existing-vpn-site ]] || fail '同域名冲突未恢复'
! grep -q '^certbot ' "$SIM/events" || fail '域名冲突后仍请求证书'
echo 'PASS: nginx 同域名冲突警告会阻止发布，不误报后端接入成功'

fixture normal
for args in '--domain ../escape' '--domain bad;name.com' '--upstream http://127.0.0.1:0' '--upstream http://127.0.0.1:65536' '--upstream http://192.0.2.1:8888' '--upstream http://127.0.0.1:8888/path' '--email bad-email' '--unknown bad'; do
  # 测试输入故意分词；不执行输入内容。
  # shellcheck disable=SC2086
  run_fail site $args
done
[[ ! -e $CONF && ! -s $SIM/events ]] || fail '非法参数产生了系统副作用'
echo 'PASS: 拒绝配置注入、非法端口、非回环后端和未知参数'

fixture normal
run_fail site --upstream-insecure
echo 'PASS: HTTP 后端不能误用跳过 TLS 校验选项'

fixture upstream-tls
run_fail bash "$OPS/add-site.sh" --domain vpn.thpvip.xyz --upstream https://127.0.0.1:8888 --email fixture@example.com
[[ ! -e $CONF ]] || fail '后端证书失败后仍发布站点'
run_ok bash "$OPS/add-site.sh" --domain vpn.thpvip.xyz --upstream https://127.0.0.1:8888 --email fixture@example.com --upstream-insecure
grep -q 'proxy_pass https://127.0.0.1:8888;' "$CONF" || fail 'HTTPS 后端丢失'
grep -q 'proxy_ssl_verify off;' "$CONF" || fail '显式 TLS 选项未渲染'
echo 'PASS: HTTPS 后端默认校验证书，只有显式选项允许回环自签名证书'

fixture normal
run_ok bash "$OPS/add-site.sh" --domain vpn.thpvip.xyz --upstream https://127.0.0.1:8888 --email fixture@example.com --upstream-server-name panel.example.com
grep -q 'proxy_ssl_verify on;' "$CONF" || fail 'HTTPS 上游验证未启用'
grep -q 'proxy_ssl_name panel.example.com;' "$CONF" || fail '上游证书域名未配置'
grep -q -- '--resolve panel.example.com:8888:127.0.0.1' "$SIM/events" || fail '后端预检未使用指定 SNI'
echo 'PASS: HTTPS 后端支持明确的证书域名及 SNI'

for mode in wrong-protocol no-dns; do
  fixture "$mode"
  run_fail site
  [[ ! -e $CONF ]] || fail '预检失败后发布站点'
  ! grep -q '^certbot ' "$SIM/events" || fail '预检失败仍请求证书'
done
echo 'PASS: 协议错误和 DNS 缺失在签发及写站点前停止'

for mode in cert-failure wrong-cert bad-gateway reload-failure syntax-failure; do
  fixture "$mode"
  printf '# Managed by server-ops/nginx\noriginal-site\n' > "$CONF"
  printf '# Managed by server-ops/nginx\noriginal-map\n' > "$MAP"
  cp "$CONF" "$SIM/original"
  cp "$MAP" "$SIM/original-map"
  run_fail site
  cmp -s "$CONF" "$SIM/original" || fail "$mode 未恢复旧站点"
  cmp -s "$MAP" "$SIM/original-map" || fail "$mode 未恢复共用 map"
  unchanged_other
done
echo 'PASS: 签发、TLS、502、重载和语法失败均恢复旧站点与共用 map'

fixture wrong-cert
run_fail site
[[ ! -e $CONF && ! -e $MAP && $(cat "$SIM/attempts") -le 10 ]] || fail '新站点失败未清理或重试无界'
echo 'PASS: 新站点失败只清理本站配置，TLS 验证不降级'

if [[ -n $TEST_NGINX_BIN ]]; then
  fixture actual-nginx
  rm "$SIM/etc/nginx/conf.d/other.example.com.conf"
  # nginx -t 也可能尝试绑定监听地址；沙箱使用系统分配的非特权端口。
  read -r test_http_port test_https_port < <(python3 - <<'PY'
import socket
with socket.socket() as http, socket.socket() as https:
    http.bind(('127.0.0.1', 0))
    https.bind(('127.0.0.1', 0))
    print(http.getsockname()[1], https.getsockname()[1])
PY
)
  sed -i -e "s|listen 80;|listen 127.0.0.1:$test_http_port;|" \
    -e "s|listen 443 ssl;|listen 127.0.0.1:$test_https_port ssl;|" \
    -e '/listen \[::\]/d' "$OPS/templates/"*.template
  cat > "$SIM/nginx.conf" <<EOF
pid $SIM/nginx.pid;
error_log $SIM/error.log;
events { worker_connections 64; }
http {
    access_log off;
    variables_hash_bucket_size 64;
    client_body_temp_path $SIM/body;
    proxy_temp_path $SIM/proxy;
    fastcgi_temp_path $SIM/fastcgi;
    uwsgi_temp_path $SIM/uwsgi;
    scgi_temp_path $SIM/scgi;
    include $SIM/etc/nginx/conf.d/*.conf;
}
EOF
  run_ok site
  grep -q 'proxy_pass http://127.0.0.1:8888;' "$CONF" || fail '真实入口未产生代理配置'
  echo 'PASS: 真实 add-site.sh 渲染的配置通过 nginx 的 64 字节变量哈希桶检查'
fi

fixture normal
run_ok bash "$OPS/install.sh" --firewall-zone external
run_ok bash "$OPS/install.sh" --firewall-zone external
unchanged_other
grep -q 'setsebool -P httpd_can_network_connect on' "$SIM/events" || fail '缺少 SELinux 配置'
grep -q 'enable --now certbot-renew.timer' "$SIM/events" || fail '续期未启用'
[[ -x $SIM/etc/letsencrypt/renewal-hooks/deploy/server-ops-nginx-reload ]] || fail '缺少证书续期重载 hook'
[[ -f $MAP ]] || fail '未安装共用 WebSocket map'
grep -q -- '--zone=external --add-service=http' "$SIM/events" || fail '忽略指定防火墙区域'
! grep -Eq '(reload firewalld|enable.*firewalld|--runtime-to-permanent|--remove)' "$SIM/events" || fail '破坏了已有防火墙'
echo 'PASS: 安装可重入，配置续期和 SELinux，仅添加指定区域的 80/443'

fixture inactive-firewall
run_ok bash "$OPS/install.sh"
! grep -q '^firewall-cmd .*--add' "$SIM/events" || fail '默认修改了防火墙'
! grep -q 'firewalld' "$SIM/events" || fail '操作了未启用的 firewalld'
echo 'PASS: 默认不操作 firewalld，保留现有 SSH 和代理入口'

for mode in occupied-port missing-timer; do
  fixture "$mode"
  run_fail bash "$OPS/install.sh"
done
fixture normal
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$SIM/etc/os-release"
run_fail bash "$OPS/install.sh"
! grep -q '^dnf ' "$SIM/events" || fail '在不支持的系统安装了包'
echo 'PASS: 端口冲突、缺失续期任务和不支持的系统给出失败'
echo "All $count nginx fixtures passed."
