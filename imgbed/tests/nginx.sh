#!/usr/bin/env bash
# 执行真实部署入口；nginx、重载及 HTTP 是模拟边界，文件回滚为真实操作。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/imgbed-nginx-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  [[ $arg != -k && $arg != --insecure ]] || exit 90
done
echo "curl $*" >> "$SIM/events"
case "${*: -1}" in
  */api/manage/list) echo 401 ;;
  */upload) if [[ $MODE == open-upload ]]; then echo 200; else echo 401; fi ;;
  *)
    count=$(cat "$SIM/attempts"); count=$((count + 1)); echo "$count" > "$SIM/attempts"
    if [[ $MODE == wrong-cert || $MODE == delayed && $count -le 3 ]]; then
      echo 'curl: (60) certificate hostname mismatch' >&2; exit 60
    fi ;;
esac
MOCK
cat > "$TEST_ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SIM/events"
[[ $MODE != reload-failure ]]
MOCK
cat > "$TEST_ROOT/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TEST_ROOT/bin/getent" <<'MOCK'
#!/usr/bin/env bash
echo 127.0.0.1
MOCK
cat > "$TEST_ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
echo 'unexpected certificate request' >&2
exit 91
MOCK
cat > "$TEST_ROOT/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
echo sleep >> "$SIM/events"
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
count=0
fixture() {
  count=$((count + 1)); export SIM="$TEST_ROOT/case$count" MODE=$1
  OPS="$SIM/ops"
  mkdir -p "$OPS/nginx" "$SIM/etc/nginx/conf.d" "$SIM/etc/letsencrypt/live/img.thpvip.xyz"
  cp "$ROOT/setup-nginx.sh" "$OPS/"
  cp "$ROOT/nginx/"* "$OPS/nginx/"
  # 沙箱替换固定系统目录，避免测试修改主机 nginx/证书。
  sed -i "s|/etc/|$SIM/etc/|g;s|/var/|$SIM/var/|g" "$OPS/setup-nginx.sh"
  cat > "$OPS/lib.sh" <<'MOCK'
OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
require_root() { :; }
lock_operation() { :; }
require_commands() { :; }
load_env() { CERTBOT_EMAIL=fixture@example.com; IMGBED_DOMAIN=img.thpvip.xyz; IMGBED_HOST_PORT=7658; }
verify_http() { :; }
die() { echo "错误：$*" >&2; exit 1; }
MOCK
  echo certificate-fixture > "$SIM/etc/letsencrypt/live/img.thpvip.xyz/fullchain.pem"
  echo 0 > "$SIM/attempts"; : > "$SIM/events"
  CONF="$SIM/etc/nginx/conf.d/img.thpvip.xyz.conf"
  MAP="$SIM/etc/nginx/conf.d/00-imgbed-websocket-map.conf"
}
fail() { echo "FAIL: $*" >&2; cat "$SIM/output" >&2; exit 1; }
run_ok() { bash "$OPS/setup-nginx.sh" > "$SIM/output" 2>&1 || fail 'setup failed'; }
run_fail() { if bash "$OPS/setup-nginx.sh" > "$SIM/output" 2>&1; then fail 'unsafe setup succeeded'; fi; }

fixture delayed
run_ok
[[ $(cat "$SIM/attempts") == 4 && -f $CONF && -f $MAP ]] || fail 'did not wait for reload'
grep -q 'HTTPS 和 nginx 已就绪' "$SIM/output" || fail 'success missing'
grep -q /upload "$SIM/events" || fail 'authentication gate omitted'
echo 'PASS: transient old certificate waits for reload, then retains site and verifies authentication'

fixture wrong-cert
echo original-site > "$CONF"; echo original-map > "$MAP"
run_fail
[[ $(cat "$SIM/attempts") -gt 1 && $(cat "$SIM/attempts") -le 15 ]] || fail 'retry is not bounded'
[[ $(cat "$CONF") == original-site && $(cat "$MAP") == original-map ]] || fail 'existing files not restored'
if grep -q /upload "$SIM/events"; then fail 'authentication ran without valid TLS'; fi
echo 'PASS: persistent certificate failure is bounded and restores existing site and map'

fixture wrong-cert
run_fail
[[ ! -e $CONF && ! -e $MAP ]] || fail 'failed new site not removed'
echo 'PASS: persistent failure removes only newly created site files'

fixture open-upload
run_fail
[[ ! -e $CONF && ! -e $MAP ]] || fail 'open upload site retained'
echo 'PASS: valid TLS does not bypass the upload authentication gate'

fixture reload-failure
run_fail
[[ $(cat "$SIM/attempts") == 0 && ! -e $CONF && ! -e $MAP ]] || fail 'reload failure ignored'
echo 'PASS: reload failure stops before HTTPS checks'
echo "All $count nginx fixtures passed."
