#!/usr/bin/env bash
# Docker/HTTP 为模拟边界；备份使用真实文件、tar、校验和与权限。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/imgbed-tests-XXXXXXXX)
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
  start)
    [[ " $* " != *' --wait '* ]] || { echo 'unknown flag: --wait' >&2; exit 1; }
    echo start >> "$SIM/events"; [[ ${FAIL:-} != start ]] || exit 1; echo 1 > "$SIM/running" ;;
  up)
    if [[ $* == --help ]]; then echo --wait-timeout; exit 0; fi
    if [[ " $* " == *' --no-recreate '* ]]; then
      [[ " $* " == *' --pull never '* && " $* " == *' --no-deps '* && " $* " == *' --wait '* ]] || exit 92
      echo "resume $*" >> "$SIM/events"
      [[ ${FAIL:-} != start ]] || exit 1
      echo 1 > "$SIM/running"
      exit 0
    fi
    echo up >> "$SIM/events"; echo "$IMGBED_IMAGE" > "$SIM/image"; echo 1 > "$SIM/running"
    [[ ${FAIL:-} != wait ]] ;;
  exec) [[ ${FAIL:-} != weak-auth ]] ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL:-} == curl ]]; then exit 7; fi
case "${*: -1}" in
  */api/manage/list) if [[ ${FAIL:-} == open-admin ]]; then echo 200; else echo 401; fi ;;
  */upload) if [[ ${FAIL:-} == open-upload ]]; then echo 200; else echo 401; fi ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 0
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL:-} == port ]]; then echo LISTEN; fi
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
OLD_IMAGE="ghcr.io/haipengtian/cloudflare-imgbed@sha256:$(printf 'a%.0s' {1..64})"
NEW_IMAGE="ghcr.io/haipengtian/cloudflare-imgbed@sha256:$(printf 'b%.0s' {1..64})"
OLD_TAG=ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.1
NEW_TAG=ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.2
count=0
fail() { echo "FAIL: $*" >&2; cat "$SIM/output" >&2; exit 1; }
pass() { echo "PASS: $*"; }
fixture() {
  count=$((count + 1)); export SIM="$TEST_ROOT/case$count/sim" FAIL=
  OPS="$TEST_ROOT/case$count/ops"; DATA="$TEST_ROOT/case$count/data"
  mkdir -p "$SIM" "$OPS" "$DATA"/{app/r2,state,backups}
  cp "$ROOT/"*.sh "$ROOT/.env.example" "$ROOT/docker-compose.yml" "$OPS/"
  bash "$OPS/init.sh" "$OLD_TAG" > "$SIM/output" 2>&1
  sed -i "s|^IMGBED_DATA_DIR=.*|IMGBED_DATA_DIR=$DATA|;s|^IMGBED_IMAGE=.*|IMGBED_IMAGE=$OLD_IMAGE|" "$OPS/.env"
  echo "$OLD_IMAGE" > "$SIM/image"; echo 1 > "$SIM/running"
  echo "$OLD_IMAGE" > "$DATA/state/current-image"
  echo sqlite-fixture > "$DATA/app/database.sqlite"
  echo wal-fixture > "$DATA/app/database.sqlite-wal"
  echo image-fixture > "$DATA/app/r2/test.png"
  : > "$SIM/events"
}
run_ok() { bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1 || fail "$* failed"; }
run_fail() { if bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1; then fail "$* unexpectedly succeeded"; fi; }
original() { [[ $(cat "$SIM/running") == 1 && $(cat "$SIM/image") == "$OLD_IMAGE" ]] || fail 'original service not restored'; grep -q "^IMGBED_IMAGE=$OLD_IMAGE$" "$OPS/.env" || fail 'original config not restored'; }

# 明确报告尚未实现的功能，避免测试以缺失文件错误结束。
[[ -f $ROOT/init.sh ]] || { echo 'FAIL: imgbed deployment entry points are not implemented'; exit 1; }
fixture
cp "$OPS/.env" "$SIM/original.env"; run_ok init.sh "$NEW_TAG"
cmp "$OPS/.env" "$SIM/original.env" || fail 'init overwrote secrets'
[[ $(stat -c %a "$OPS/.env") == 600 ]] || fail 'env permissions'
pass 'initialization preserves existing credentials and uses mode 600'

fixture
run_fail update.sh ghcr.io/haipengtian/cloudflare-imgbed:latest
[[ ! -s $SIM/events ]] || fail 'invalid image caused changes'
pass 'moving tags are rejected before mutation'

fixture
# 故意写入字面值，验证配置不会作为 shell 执行。
# shellcheck disable=SC2016
sed -i 's|^BASIC_PASS=.*|BASIC_PASS=$(touch /tmp/imgbed-should-never-exist)|' "$OPS/.env"
run_fail backup.sh
[[ ! -s $SIM/events ]] || fail 'unsafe env caused Docker work'
pass 'configuration is parsed as data, never executed'

fixture
run_ok backup.sh
backup=$(cat "$DATA/state/last-backup")
[[ $(cat "$SIM/running") == 1 ]] || fail 'backup did not resume app'
tar -tzf "$backup/data.tar.gz" | grep -q database.sqlite-wal || fail 'SQLite WAL omitted'
tar -tzf "$backup/data.tar.gz" | grep -q r2/test.png || fail 'local objects omitted'
(cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail 'checksum invalid'
[[ $(stat -c %a "$backup/deployment.env") == 600 ]] || fail 'backup permissions'
pass 'backup stops writers, archives SQLite/WAL and local objects, verifies checksums and resumes'

fixture
run_ok backup.sh --keep-stopped
[[ $(cat "$SIM/running") == 0 ]] || fail 'migration backup resumed old writers'
[[ -f $(cat "$DATA/state/last-backup")/data.tar.gz ]] || fail 'migration backup missing'
pass 'migration backup keeps the old service stopped after a complete snapshot'

fixture
export FAIL=archive; run_fail backup.sh --keep-stopped; original
pass 'failed migration backup resumes the original service'

fixture
run_fail backup.sh --unsupported
[[ ! -s $SIM/events ]] || fail 'invalid backup option mutated service'
pass 'invalid backup options are rejected before stopping service'

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
pass 'failed target is paused because startup may have migrated SQLite'

fixture
run_ok update.sh "$NEW_TAG"
[[ $(cat "$DATA/state/previous-image") == "$OLD_IMAGE" ]] || fail 'previous image not recorded'
[[ $(cat "$SIM/image") == "$NEW_IMAGE" ]] || fail 'new image not running'
pass 'successful upgrade records image digests and the prior release'

for failure in open-admin open-upload curl weak-auth; do
  fixture; export FAIL=$failure; run_fail update.sh "$NEW_TAG"
  [[ $(cat "$SIM/running") == 0 ]] || fail 'unsafe or unhealthy target still running'
  pass "deployment gate rejects $failure"
done

for failure in wait open-admin; do
  fixture; export FAIL=$failure; run_fail install.sh
  [[ $(cat "$SIM/running") == 0 && -f $DATA/state/failed-install ]] || fail 'failed install left application running'
  pass "failed installation pauses target after $failure"
done

fixture
echo "$NEW_IMAGE" > "$DATA/state/previous-image"
run_fail rollback.sh; [[ ! -s $SIM/events ]] || fail 'unconfirmed rollback changed service'
run_ok rollback.sh --database-compatible
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

# 将真实旧机备份移到传输目录，模拟没有配置、容器与数据的新机。
restore_fixture() {
  fixture
  run_ok backup.sh --keep-stopped
  backup=$(cat "$DATA/state/last-backup")
  mv "$DATA" "$DATA-old"
  backup="$DATA-old/backups/$(basename "$backup")"
  mv "$OPS/.env" "$SIM/original.env"
  rm "$SIM/image" "$SIM/running"
  : > "$SIM/events"
}
[[ -f $ROOT/restore.sh ]] || { echo 'FAIL: missing first-restore entry point'; exit 1; }
restore_fixture
run_ok restore.sh "$backup"
cmp "$OPS/.env" "$SIM/original.env" || fail 'restore changed original secrets or settings'
for file in database.sqlite database.sqlite-wal r2/test.png; do
  cmp "$DATA/app/$file" "$DATA-old/app/$file" || fail "restore lost $file"
done
[[ $(cat "$SIM/image") == "$OLD_IMAGE" && $(cat "$SIM/running") == 1 ]] || fail 'restore did not start original image'
[[ $(cat "$DATA/state/current-image") == "$OLD_IMAGE" ]] || fail 'restore did not record original image'
[[ $(stat -c %a "$OPS/.env") == 600 ]] || fail 'restored env permissions'
for key in BASIC_PASS AUTH_CODE AI_CONFIG_SECRET; do
  value=$(sed -n "s/^$key=//p" "$OPS/.env")
  if grep -Fq "$value" "$SIM/output"; then fail 'restore printed a secret'; fi
done
pass 'first restore preserves original credentials, SQLite/WAL, local objects and exact image'

for failure in checksum missing failed; do
  restore_fixture
  case "$failure" in
    checksum) echo corrupt >> "$backup/data.tar.gz" ;;
    missing) rm "$backup/deployment.env" ;;
    failed) touch "$backup/FAILED" ;;
  esac
  run_fail restore.sh "$backup"
  [[ ! -e $OPS/.env && ! -e $DATA && ! -s $SIM/events ]] || fail 'invalid backup mutated destination'
  pass "restore rejects $failure backup before mutation"
done

for conflict in env app container port; do
  restore_fixture
  case "$conflict" in
    env) cp "$SIM/original.env" "$OPS/.env" ;;
    app) mkdir -p "$DATA/app"; echo sentinel > "$DATA/app/sentinel" ;;
    container) echo "$NEW_IMAGE" > "$SIM/image"; echo 1 > "$SIM/running" ;;
    port) export FAIL=port ;;
  esac
  run_fail restore.sh "$backup"
  [[ ! -s $SIM/events ]] || fail 'restore modified a conflicting deployment'
  if [[ $conflict == app ]]; then [[ $(cat "$DATA/app/sentinel") == sentinel ]] || fail 'restore overwrote existing data'; fi
  if [[ $conflict == env ]]; then cmp "$SIM/original.env" "$OPS/.env" || fail 'restore overwrote existing env'; fi
  pass "restore refuses existing $conflict"
done

restore_fixture
export FAIL=pull; run_fail restore.sh "$backup"
[[ ! -e $OPS/.env && ! -e $DATA ]] || fail 'pull failure committed restored data'
pass 'restore pulls image before committing local data or configuration'

restore_fixture
export FAIL=wait; run_fail restore.sh "$backup"
[[ $(cat "$SIM/running") == 0 && -f $DATA/state/failed-restore ]] || fail 'failed restore target not paused'
cmp "$DATA/app/database.sqlite" "$DATA-old/app/database.sqlite" || fail 'failed restore deleted recovered data'
cmp "$OPS/.env" "$SIM/original.env" || fail 'failed restore deleted recovered configuration'
pass 'startup failure pauses restored target and preserves recovered data for diagnosis'
echo "All $count isolated fixtures passed."
