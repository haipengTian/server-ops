#!/usr/bin/env bash
# 隔离文件系统测试：Docker/HTTP/数据库用模拟边界，文件归档、权限和校验用真实工具。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sub2api-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export REAL_CP REAL_MKTEMP REAL_SHA256SUM REAL_MV
REAL_CP=$(command -v cp)
REAL_MKTEMP=$(command -v mktemp)
REAL_SHA256SUM=$(command -v sha256sum)
REAL_MV=$(command -v mv)
mkdir "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  info) exit 0 ;;
  image)
    case "$3" in
      *custom.2*) printf '%s\n' "$NEW_IMAGE" ;;
      *@sha256:*) printf '%s\n' "$3" ;;
      *) printf '%s\n' "$OLD_IMAGE" ;;
    esac
    exit 0 ;;
  inspect) cat "$SIM/image"; exit 0 ;;
  compose) shift ;;
  *) exit 2 ;;
esac
while [[ ${1:-} == --* || ${1:-} == -f || ${1:-} == -p ]]; do shift 2; done
cmd=$1; shift
case "$cmd" in
  version|config) exit 0 ;;
  pull) printf 'pull %s\n' "$SUB2API_IMAGE" >> "$SIM/events" ;;
  ps)
    service=${*: -1}
    if [[ ${FAIL:-} == ps-error && $service == sub2api && $(cat "$SIM/running") == 0 ]]; then exit 1; fi
    if [[ $service == postgres ]]; then printf 'db\n'
    elif [[ -f $SIM/image ]] && { [[ " $* " != *' --status running '* ]] || [[ $(cat "$SIM/running") == 1 ]]; }; then printf 'app\n'; fi ;;
  stop)
    printf 'stop\n' >> "$SIM/events"
    [[ ${FAIL:-} != target-stop || ! -e $SIM/target-started ]] || exit 1
    printf '0\n' > "$SIM/running" ;;
  start)
    printf 'start %s\n' "$(cat "$SIM/image")" >> "$SIM/events"
    [[ ${FAIL:-} != start ]] || exit 1
    printf '1\n' > "$SIM/running" ;;
  up)
    if [[ $* == --help ]]; then printf '%s\n' '--wait-timeout'; exit 0; fi
    printf 'up %s\n' "$SUB2API_IMAGE" >> "$SIM/events"
    printf '%s\n' "$SUB2API_IMAGE" > "$SIM/image"
    printf '1\n' > "$SIM/running"
    touch "$SIM/target-started"
    [[ ${FAIL:-} != wait && ${FAIL:-} != target-stop ]] || exit 1 ;;
  exec)
    if [[ $* == *pg_dump* ]]; then
      printf 'dump\n' >> "$SIM/events"
      [[ ${FAIL:-} != dump ]] || exit 1
      printf 'synthetic database backup\n'
    elif [[ $* == *pg_restore* ]]; then
      input=$(cat); [[ -n $input ]] || exit 1
    else exit 2; fi ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl\n' >> "$SIM/events"
[[ ${FAIL:-} != curl ]]
MOCK
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
printf '0\n'
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TEST_ROOT/bin/cp" <<'MOCK'
#!/usr/bin/env bash
[[ ${FAIL:-} != copy || $* != *backups*deployment.env* ]] || exit 1
exec "$REAL_CP" "$@"
MOCK
cat > "$TEST_ROOT/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
[[ ${FAIL:-} != hash ]] || exit 1
exec "$REAL_SHA256SUM" "$@"
MOCK
cat > "$TEST_ROOT/bin/mktemp" <<'MOCK'
#!/usr/bin/env bash
[[ ${FAIL:-} != env-temp || $* != */.env.* ]] || exit 1
[[ ${FAIL:-} != state-temp || $* != */.state.* ]] || exit 1
exec "$REAL_MKTEMP" "$@"
MOCK
cat > "$TEST_ROOT/bin/mv" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL:-} == previous-state && $* == *state/previous-image && ! -e $SIM/failed-once ]]; then
  touch "$SIM/failed-once"
  exit 1
fi
exec "$REAL_MV" "$@"
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
OLD_IMAGE="ghcr.io/haipengtian/sub2api@sha256:$(printf 'a%.0s' {1..64})"
NEW_IMAGE="ghcr.io/haipengtian/sub2api@sha256:$(printf 'b%.0s' {1..64})"
export OLD_IMAGE NEW_IMAGE
OLD_TAG=ghcr.io/haipengtian/sub2api:0.2.15-custom.1
NEW_TAG=ghcr.io/haipengtian/sub2api:0.2.15-custom.2
count=0
fixture() {
  count=$((count + 1))
  export SIM="$TEST_ROOT/case$count/sim" FAIL=
  OPS="$TEST_ROOT/case$count/ops"
  DATA="$TEST_ROOT/case$count/data"
  mkdir -p "$SIM" "$OPS" "$DATA"/{app,state,backups}
  cp "$ROOT/"*.sh "$ROOT/.env.example" "$ROOT/docker-compose.yml" "$OPS/"
  bash "$OPS/init.sh" "$OLD_TAG" > "$SIM/output" 2>&1
  sed -i "s|^SUB2API_DATA_DIR=.*|SUB2API_DATA_DIR=$DATA|;s/^ADMIN_EMAIL=.*/ADMIN_EMAIL=test@example.com/;s|^SUB2API_IMAGE=.*|SUB2API_IMAGE=$OLD_IMAGE|" "$OPS/.env"
  printf '%s\n' "$OLD_IMAGE" > "$SIM/image"
  printf '1\n' > "$SIM/running"
  printf '%s\n' "$OLD_IMAGE" > "$DATA/state/current-image"
  printf 'fixture\n' > "$DATA/app/config.yaml"
  : > "$SIM/events"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$SIM/output" >&2; exit 1; }
run_ok() { bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1 || fail "$* should succeed"; }
run_fail() { if bash "$OPS/$1" "${@:2}" > "$SIM/output" 2>&1; then fail "$* should fail"; fi; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected $2, got $1"; }
assert_running() { assert_eq "$(cat "$SIM/running")" "$1"; }
assert_original() {
  assert_running 1
  assert_eq "$(cat "$SIM/image")" "$OLD_IMAGE"
  grep -qx "SUB2API_IMAGE=$OLD_IMAGE" "$OPS/.env" || fail 'original env not restored'
  if grep -q '^up ' "$SIM/events"; then fail 'new image attempted before valid backup'; fi
}
pass() { printf 'PASS: %s\n' "$1"; }

fixture
before=$(sha256sum "$OPS/.env")
run_ok init.sh "$NEW_TAG"
assert_eq "$(sha256sum "$OPS/.env")" "$before"
assert_eq "$(stat -c %a "$OPS/.env")" 600
pass 'initialization preserves secrets and restricts permissions'

fixture
# shellcheck disable=SC2016
printf 'ADMIN_EMAIL=$(touch /tmp/sub2api-injection)\n' >> "$OPS/.env"
run_fail status.sh
[[ ! -s $SIM/events ]] || fail 'invalid env reached docker'
pass 'duplicate or executable env values rejected'

fixture
# shellcheck disable=SC2016
sed -i 's/^ADMIN_EMAIL=.*/ADMIN_EMAIL=$(id)/' "$OPS/.env"
run_fail status.sh
pass 'shell substitution is treated as invalid data'

fixture
run_fail update.sh ghcr.io/haipengtian/sub2api:latest
assert_running 1
pass 'floating image tags rejected'

fixture
rm -f "$SIM/image" "$DATA/state/current-image"
printf '0\n' > "$SIM/running"
run_ok install.sh
assert_running 1
assert_eq "$(cat "$DATA/state/current-image")" "$OLD_IMAGE"
pass 'installation records resolved digest'

fixture
run_ok update.sh "$NEW_TAG"
assert_running 1
assert_eq "$(cat "$SIM/image")" "$NEW_IMAGE"
assert_eq "$(cat "$DATA/state/previous-image")" "$OLD_IMAGE"
backup=$(cat "$DATA/state/last-backup")
(cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail 'backup hashes invalid'
assert_eq "$(stat -c %a "$backup")" 700
assert_eq "$(stat -c %a "$backup/deployment.env")" 600
assert_eq "$(cat "$backup/image")" "$OLD_IMAGE"
[[ $(grep -n '^dump$' "$SIM/events" | cut -d: -f1) -lt $(grep -n '^up ' "$SIM/events" | cut -d: -f1) ]] || fail 'up before dump'
pass 'upgrade backs up before launch, pins digest, protects backup'

for error in dump copy hash state-temp env-temp previous-state ps-error; do
  fixture
  saved_previous="ghcr.io/haipengtian/sub2api@sha256:$(printf 'c%.0s' {1..64})"
  printf '%s\n' "$saved_previous" > "$DATA/state/previous-image"
  export FAIL=$error
  run_fail update.sh "$NEW_TAG"
  assert_original
  assert_eq "$(cat "$DATA/state/previous-image")" "$saved_previous"
  pass "upgrade $error failure restores original service"
done

fixture
export FAIL=wait
run_fail update.sh "$NEW_TAG"
assert_running 0
assert_eq "$(cat "$DATA/state/failed-upgrade")" "$NEW_IMAGE"
if grep -q '^start ' "$SIM/events"; then fail 'old image restarted after target launch'; fi
if grep -q '^curl$' "$SIM/events"; then fail 'failed compose wait was masked by curl'; fi
pass 'compose failure pauses target, without automatic old-image rollback'

fixture
export FAIL=curl
run_fail update.sh "$NEW_TAG"
assert_running 0
pass 'HTTP health failure pauses target'

fixture
export FAIL=target-stop
run_fail update.sh "$NEW_TAG"
assert_running 1
grep -q '无法确认应用已暂停' "$SIM/output" || fail 'stop failure was hidden'
if grep -q '^start ' "$SIM/events"; then fail 'old image restarted after stop failure'; fi
pass 'failed container stop is reported without claiming successful pause'

fixture
printf '%s\n' "$NEW_IMAGE" > "$DATA/state/previous-image"
run_fail rollback.sh
[[ ! -s $SIM/events ]] || fail 'rollback without compatibility flag performed work'
export FAIL=dump
run_fail rollback.sh --database-compatible
assert_original
pass 'rollback requires compatibility flag and resumes on backup failure'

fixture
printf '%s\n' "$NEW_IMAGE" > "$DATA/state/previous-image"
run_ok rollback.sh --database-compatible
assert_running 1
assert_eq "$(cat "$SIM/image")" "$NEW_IMAGE"
pass 'compatible rollback creates backup and starts chosen previous image'

fixture
run_ok backup.sh
assert_running 1
export FAIL=start
run_fail backup.sh
assert_running 0
pass 'backup resumes original service and reports restart failure'

fixture
printf '0\n' > "$SIM/running"
run_ok backup.sh
assert_running 0
pass 'backup preserves an already paused service'

fixture
printf '0\n' > "$SIM/running"
printf '%s\n' "$NEW_IMAGE" > "$DATA/state/previous-image"
export FAIL=dump
run_fail rollback.sh --database-compatible
assert_running 0
if grep -q '^start ' "$SIM/events"; then fail 'paused service restarted after failed rollback'; fi
pass 'failed rollback preserves an already paused service'
printf 'All %s isolated fixtures passed.\n' "$count"
