#!/usr/bin/env bash
# Docker/HTTP 为模拟边界；备份使用真实文件、tar、校验和与权限。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/cliproxyapi-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  info) exit 0 ;;
  image) if [[ $3 == *custom.2* ]]; then echo "$NEW_IMAGE"; else echo "$OLD_IMAGE"; fi; exit 0 ;;
  inspect) cat "$SIM/image"; exit 0 ;;
  compose) shift ;;
  *) exit 2 ;;
esac
while [[ ${1:-} == --* || ${1:-} == -f || ${1:-} == -p ]]; do shift 2; done
cmd=$1; shift
case "$cmd" in
  version|config) exit 0 ;;
  pull) echo pull >> "$SIM/events"; [[ ${FAIL:-} != pull ]] ;;
  ps) if [[ -f $SIM/image ]] && { [[ " $* " != *' --status running '* ]] || [[ $(cat "$SIM/running") == 1 ]]; }; then echo app; fi ;;
  stop) echo stop >> "$SIM/events"; echo 0 > "$SIM/running" ;;
  start) echo start >> "$SIM/events"; [[ ${FAIL:-} != start ]] || exit 1; echo 1 > "$SIM/running" ;;
  up)
    if [[ $* == --help ]]; then echo --wait-timeout; exit 0; fi
    echo up >> "$SIM/events"; echo "$CLIPROXY_IMAGE" > "$SIM/image"; echo 1 > "$SIM/running"
    [[ ${FAIL:-} != wait ]] ;;
  exec) [[ ${FAIL:-} != weak-auth && ${FAIL:-} != disabled-management ]] ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL:-} == curl ]]; then exit 7; fi
case "${*: -1}" in
  */v8/management/config) exit 93 ;;
  */v1/models) if [[ ${FAIL:-} == open-api ]]; then echo 200; else echo 401; fi ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 0
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TEST_ROOT/bin/chown" <<'MOCK'
#!/usr/bin/env bash
# Ownership is checked by the real non-root container regression.
exit 0
MOCK
REAL_TAR=$(command -v tar); export REAL_TAR
cat > "$TEST_ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
[[ ${FAIL:-} != archive ]] || exit 1
exec "$REAL_TAR" "$@"
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
export OLD_IMAGE NEW_IMAGE
OLD_IMAGE="ghcr.io/haipengtian/cliproxyapi@sha256:$(printf 'a%.0s' {1..64})"
NEW_IMAGE="ghcr.io/haipengtian/cliproxyapi@sha256:$(printf 'b%.0s' {1..64})"
OLD_TAG=ghcr.io/haipengtian/cliproxyapi:8.0.20-custom.1
NEW_TAG=ghcr.io/haipengtian/cliproxyapi:8.0.20-custom.2
count=0
fail() { echo "FAIL: $*" >&2; cat "$SIM/output" >&2; exit 1; }
pass() { echo "PASS: $*"; }
fixture() {
  count=$((count + 1)); export SIM="$TEST_ROOT/case$count/sim" FAIL=
  OPS="$TEST_ROOT/case$count/ops"; DATA="$TEST_ROOT/case$count/data"
  mkdir -p "$SIM" "$OPS" "$DATA"/{config,auths,plugins,secrets,state,backups}
  cp "$ROOT/"*.sh "$ROOT/.env.example" "$ROOT/docker-compose.yml" "$ROOT/config.example.yaml" "$OPS/"
  sed -i "s|^CLIPROXY_DATA_DIR=.*|CLIPROXY_DATA_DIR=$DATA|" "$OPS/.env.example"
  bash "$OPS/init.sh" "$OLD_TAG" > "$SIM/output" 2>&1 || fail 'fixture initialization failed'
  sed -i "s|^CLIPROXY_DATA_DIR=.*|CLIPROXY_DATA_DIR=$DATA|;s|^CLIPROXY_IMAGE=.*|CLIPROXY_IMAGE=$OLD_IMAGE|" "$OPS/.env"
  echo "$OLD_IMAGE" > "$SIM/image"; echo 1 > "$SIM/running"
  echo "$OLD_IMAGE" > "$DATA/state/current-image"
  echo configuration-fixture > "$DATA/config/config.yaml"
  echo oauth-fixture > "$DATA/auths/codex.json"
  echo plugin-fixture > "$DATA/plugins/fixture.so"
  : > "$SIM/events"
}
run_ok() { bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1 || fail "$* failed"; }
run_fail() { if bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1; then fail "$* unexpectedly succeeded"; fi; }
original() { [[ $(cat "$SIM/running") == 1 && $(cat "$SIM/image") == "$OLD_IMAGE" ]] || fail 'original service not restored'; grep -q "^CLIPROXY_IMAGE=$OLD_IMAGE$" "$OPS/.env" || fail 'original config not restored'; }

# 明确报告尚未实现的功能，避免测试以缺失文件错误结束。
[[ -f $ROOT/init.sh ]] || { echo 'FAIL: cliproxyapi deployment entry points are not implemented'; exit 1; }
fixture
cp "$OPS/.env" "$SIM/original.env"; run_ok init.sh "$NEW_TAG"
cmp "$OPS/.env" "$SIM/original.env" || fail 'init overwrote secrets'
[[ $(stat -c %a "$OPS/.env") == 600 ]] || fail 'env permissions'
[[ $(stat -c %a "$DATA/secrets/initial-keys") == 600 && $(stat -c %a "$DATA/config/config.yaml") == 600 ]] || fail 'secret permissions'
cp "$DATA/config/config.yaml" "$SIM/original.config"; run_ok init.sh "$NEW_TAG"; cmp "$DATA/config/config.yaml" "$SIM/original.config" || fail 'config overwritten'
pass 'initialization preserves existing credentials and uses mode 600'

fixture
run_fail update.sh ghcr.io/haipengtian/cliproxyapi:latest
[[ ! -s $SIM/events ]] || fail 'invalid image caused changes'
pass 'moving tags are rejected before mutation'

fixture
# 故意写入字面值，验证配置不会作为 shell 执行。
# shellcheck disable=SC2016
sed -i 's|^CLIPROXY_DOMAIN=.*|CLIPROXY_DOMAIN=$(touch /tmp/cliproxyapi-should-never-exist)|' "$OPS/.env"
run_fail backup.sh
[[ ! -s $SIM/events ]] || fail 'unsafe env caused Docker work'
pass 'configuration is parsed as data, never executed'

fixture
run_ok backup.sh
backup=$(cat "$DATA/state/last-backup")
[[ $(cat "$SIM/running") == 1 ]] || fail 'backup did not resume app'
tar -tzf "$backup/data.tar.gz" | grep -q auths/codex.json || fail 'OAuth credentials omitted'
tar -tzf "$backup/data.tar.gz" | grep -q plugins/fixture.so || fail 'plugins omitted'
(cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail 'checksum invalid'
[[ $(stat -c %a "$backup/deployment.env") == 600 ]] || fail 'backup permissions'
pass 'backup stops writers, archives configuration and OAuth credentials, verifies checksums and resumes'

fixture
export FAIL=archive; run_fail update.sh "$NEW_TAG"; original
[[ -n $(find "$DATA/backups" -name FAILED -print -quit) ]] || fail 'failed backup not marked'
pass 'backup failure preserves old image and resumes original service'

fixture
export FAIL=pull; run_fail update.sh "$NEW_TAG"; original
[[ $(cat "$SIM/events") == pull ]] || fail 'pull failure stopped service'
pass 'image pull failure leaves running deployment untouched'

fixture
export FAIL=wait; run_fail update.sh "$NEW_TAG"
[[ $(cat "$SIM/running") == 0 && -f $DATA/state/failed-upgrade ]] || fail 'failed target not paused'
[[ $(cat "$SIM/image") == "$NEW_IMAGE" ]] || fail 'unsafe automatic rollback'
pass 'failed target is paused because startup may have changed configuration or credentials'

fixture
run_ok update.sh "$NEW_TAG"
[[ $(cat "$DATA/state/previous-image") == "$OLD_IMAGE" ]] || fail 'previous image not recorded'
[[ $(cat "$SIM/image") == "$NEW_IMAGE" ]] || fail 'new image not running'
pass 'successful upgrade records image digests and the prior release'

for failure in disabled-management open-api curl weak-auth; do
  fixture; export FAIL=$failure; run_fail update.sh "$NEW_TAG"
  [[ $(cat "$SIM/running") == 0 ]] || fail 'unsafe or unhealthy target still running'
  pass "deployment gate rejects $failure"
done

for failure in wait disabled-management; do
  fixture; export FAIL=$failure; run_fail install.sh
  [[ $(cat "$SIM/running") == 0 && -f $DATA/state/failed-install ]] || fail 'failed install left application running'
  pass "failed installation pauses target after $failure"
done

fixture
echo "$NEW_IMAGE" > "$DATA/state/previous-image"
run_fail rollback.sh; [[ ! -s $SIM/events ]] || fail 'unconfirmed rollback changed service'
run_ok rollback.sh --config-compatible
[[ $(cat "$SIM/image") == "$NEW_IMAGE" ]] || fail 'compatible rollback failed'
pass 'rollback requires explicit migration compatibility and creates a backup'

fixture
echo 0 > "$SIM/running"; run_ok backup.sh
[[ $(cat "$SIM/running") == 0 ]] || fail 'paused app restarted'
pass 'backup preserves an already stopped service'

fixture
export FAIL=start; run_fail backup.sh
[[ $(cat "$SIM/running") == 0 ]] || fail 'restart failure hidden'
pass 'backup restart failure is reported'

fixture
rm "$DATA/config/config.yaml"
run_fail install.sh
[[ ! -s $SIM/events ]] || fail 'missing config caused Docker mutation'
pass 'installation rejects missing configuration before pulling or starting'

fixture
rm "$DATA/config/config.yaml"
cp "$DATA/secrets/initial-keys" "$SIM/original.keys"
run_fail init.sh "$NEW_TAG"
cmp "$SIM/original.keys" "$DATA/secrets/initial-keys" || fail 'interrupted keys replaced'
[[ ! -e $DATA/config/config.yaml ]] || fail 'interrupted config recreated'
pass 'interrupted initialization preserves original keys and stops'

fixture
rmdir "$DATA/backups"
ln -s "$SIM" "$DATA/backups"
run_fail init.sh "$NEW_TAG"
pass 'initialization rejects a symlinked data subdirectory'
echo "All $count isolated fixtures passed."
