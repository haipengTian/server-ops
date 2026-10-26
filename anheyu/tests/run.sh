#!/usr/bin/env bash
# Docker/HTTP 是模拟边界；归档、校验、文件与权限为真实操作。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/anheyu-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  info) exit 0 ;;
  inspect)
    if [[ $* == *'.Source'* ]]; then
      for name in data themes static backup; do
        if [[ $* == *"/anheyu/$name"* ]]; then echo "$SOURCE/$name"; exit; fi
      done
    fi
    echo "sha256:$2"; exit 0 ;;
  image)
    case "$3" in
      *anheyu*) echo "$APP_IMAGE" ;;
      *postgres*) echo "$PG_IMAGE" ;;
      *redis*) echo "$REDIS_IMAGE" ;;
    esac
    exit 0 ;;
  volume) [[ ${FAIL:-} == volume ]]; exit ;;
  run)
    echo seed-redis >> "$SIM/events"
    [[ -f $BUNDLE/redis.rdb ]] || exit 4
    cp "$BUNDLE/redis.rdb" "$SIM/restored.rdb"
    exit 0 ;;
  compose) shift ;;
  *) exit 2 ;;
esac
project_root=
while [[ ${1:-} == --* || ${1:-} == -f || ${1:-} == -p ]]; do
  if [[ $1 == --project-directory ]]; then project_root=$2; fi
  shift 2
done
cmd=$1; shift
case "$cmd" in
  version) exit 0 ;;
  config)
    if [[ ${1:-} == --format ]]; then
      echo '{"services":{"anheyu":{"ports":[{"host_ip":"127.0.0.1","published":"8091","target":8091}]}}}'
    elif [[ ${1:-} == --images ]]; then
      printf '%s\n' "$APP_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE"
    fi ;;
  ps)
    service=${*: -1}
    if [[ $project_root == "$SOURCE" || ${FAIL:-} == container || -f $SIM/new-started ]]; then
      if [[ " $* " != *' --status running '* || $(cat "$SIM/running") == 1 ]]; then echo "$service"; fi
    fi ;;
  stop) echo "stop $*" >> "$SIM/events"; echo 0 > "$SIM/running" ;;
  create)
    [[ " $* " != *' --no-deps '* ]] || { echo 'unknown flag: --no-deps' >&2; exit 94; }
    echo create >> "$SIM/events" ;;
  pull) echo pull >> "$SIM/events"; [[ ${FAIL:-} != pull ]] ;;
  up)
    if [[ $* == --help ]]; then echo --wait-timeout; exit; fi
    echo "up $*" >> "$SIM/events"
    if [[ ${*: -1} == anheyu ]]; then
      if [[ $project_root != "$SOURCE" ]]; then
        [[ -f $SIM/restored.dump && -f $SIM/restored.rdb ]] || exit 41
      fi
      echo 1 > "$SIM/running"
    fi
    if [[ $project_root != "$SOURCE" ]]; then touch "$SIM/new-started"; fi
    [[ ${FAIL:-} != start ]] ;;
  exec)
    shift # -T
    service=$1; shift
    case "$1" in
      pg_dump)
        echo dump >> "$SIM/events"
        [[ $(cat "$SIM/running") == 0 ]] || exit 42
        [[ ${FAIL:-} != dump ]] || exit 1
        printf 'PGDMP-fixture\n' ;;
      pg_restore)
        echo restore-db >> "$SIM/events"
        [[ " $* " == *' --exit-on-error '* && " $* " == *' --single-transaction '* ]] || exit 43
        cat > "$SIM/restored.dump"
        [[ ${FAIL:-} != restore ]] ;;
      psql)
        if [[ ${FAIL:-} == counts && $project_root != "$SOURCE" ]]; then echo 'users|0'; else printf 'users|2\narticles|3\nessays|4\n'; fi ;;
      sh)
        [[ $service == redis ]] || exit 2
        echo redis-snapshot >> "$SIM/events"
        [[ ${FAIL:-} != redis ]] || exit 1
        printf 'REDIS-fixture\n' ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
[[ ${FAIL:-} != http ]] || exit 7
if [[ $* == *api/public/essays* ]]; then
  if [[ ${FAIL:-} == business ]]; then echo '{"code":500}'; else echo '{"code":200,"data":{"list":[],"total":0}}'; fi
fi
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL:-} == port ]]; then echo LISTEN; fi
exit 0
MOCK
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 0
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
export APP_IMAGE PG_IMAGE REDIS_IMAGE
APP_IMAGE="ghcr.io/haipengtian/anheyu-app@sha256:$(printf a%.0s {1..64})"
PG_IMAGE="postgres@sha256:$(printf b%.0s {1..64})"
REDIS_IMAGE="redis@sha256:$(printf c%.0s {1..64})"
count=0
fixture() {
  count=$((count + 1))
  export SIM="$TEST_ROOT/case$count/sim" SOURCE="$TEST_ROOT/case$count/source" FAIL='' BUNDLE=''
  DEST="$TEST_ROOT/case$count/destination"
  mkdir -p "$SIM" "$SOURCE"/{data,themes,static,backup}
  for name in data themes static backup; do echo "original-$name" > "$SOURCE/$name/fixture"; done
  printf 'ANHEYU_TAG=custom-original\nANHEYU_DATABASE_PASSWORD=Example-Pg!2026\nANHEYU_REDIS_PASSWORD=Example-Redis!2026\nREVALIDATE_TOKEN=Example-Token!2026\n' > "$SOURCE/.env"
  cp "$ROOT/docker-compose.prod.yml" "$SOURCE/"
  echo 1 > "$SIM/running"
  : > "$SIM/events"
}
fail() { echo "FAIL: $*" >&2; cat "$SIM/output" >&2; exit 1; }
run_ok() { bash "$ROOT/$1" "${@:2}" > "$SIM/output" 2>&1 || fail "$* failed"; }
run_fail() { if bash "$ROOT/$1" "${@:2}" > "$SIM/output" 2>&1; then fail "$* unexpectedly succeeded"; fi; }
backup_fixture() {
  fixture
  run_ok backup.sh "$SOURCE"
  BUNDLE=$(cat "$SOURCE/migration-backups/last-backup")
  : > "$SIM/events"
}
[[ -f $ROOT/backup.sh && -f $ROOT/restore.sh ]] || { echo 'FAIL: blog migration entry points are missing'; exit 1; }
fixture
run_ok backup.sh "$SOURCE"
BUNDLE=$(cat "$SOURCE/migration-backups/last-backup")
[[ $(cat "$SIM/running") == 0 ]] || fail 'successful migration backup resumed old writers'
cmp "$SOURCE/.env" "$BUNDLE/deployment.env" || fail 'original credentials changed'
for name in data themes static backup; do tar -tzf "$BUNDLE/files.tar.gz" | grep -q "$name/fixture" || fail "missing $name"; done
[[ -s $BUNDLE/database.dump && -s $BUNDLE/redis.rdb ]] || fail 'database or redis snapshot missing'
grep -Fq "$APP_IMAGE" "$BUNDLE/docker-compose.images.yml" || fail 'actual image digest missing'
(cd "$BUNDLE" && sha256sum -c SHA256SUMS >/dev/null) || fail 'backup checksum'
[[ $(stat -c %a "$BUNDLE") == 700 && $(stat -c %a "$BUNDLE/deployment.env") == 600 ]] || fail 'backup permissions'
echo 'PASS: backup freezes application, saves PostgreSQL, Redis, all mounts and original configuration'

for failure in dump redis; do
  fixture; export FAIL=$failure; run_fail backup.sh "$SOURCE"
  [[ $(cat "$SIM/running") == 1 ]] || fail 'failed backup did not resume old application'
  [[ -n $(find "$SOURCE/migration-backups" -name FAILED -print -quit) ]] || fail 'failed backup not marked'
  echo "PASS: failed $failure snapshot resumes original service"
done

backup_fixture
run_ok restore.sh "$BUNDLE" "$DEST"
cmp "$SOURCE/.env" "$DEST/.env" || fail 'restored credentials changed'
cmp "$BUNDLE/database.dump" "$SIM/restored.dump" || fail 'database dump not restored'
cmp "$BUNDLE/redis.rdb" "$SIM/restored.rdb" || fail 'redis snapshot not restored'
for name in data themes static backup; do cmp "$SOURCE/$name/fixture" "$DEST/$name/fixture" || fail "restored $name differs"; done
[[ $(cat "$SIM/running") == 1 && -f $DEST/MIGRATION_COMPLETE ]] || fail 'restore not completed'
if grep -q 'Example-' "$SIM/output"; then fail 'restore leaked credentials'; fi
echo 'PASS: restore preserves credentials, all files, Redis and database before starting application'

for conflict in directory container volume port; do
  backup_fixture
  if [[ $conflict == directory ]]; then mkdir "$DEST"; echo sentinel > "$DEST/sentinel"; else export FAIL=$conflict; fi
  run_fail restore.sh "$BUNDLE" "$DEST"
  [[ ! -s $SIM/events ]] || fail 'conflict caused Docker mutation'
  echo "PASS: restore refuses existing $conflict"
done

for failure in checksum missing failed; do
  backup_fixture
  case "$failure" in
    checksum) echo corrupt >> "$BUNDLE/database.dump" ;;
    missing) rm "$BUNDLE/deployment.env" ;;
    failed) touch "$BUNDLE/FAILED" ;;
  esac
  run_fail restore.sh "$BUNDLE" "$DEST"
  [[ ! -e $DEST && ! -s $SIM/events ]] || fail 'invalid backup mutated destination'
  echo "PASS: restore rejects $failure backup"
done

backup_fixture
export FAIL=pull; run_fail restore.sh "$BUNDLE" "$DEST"
[[ ! -e $DEST ]] || fail 'image pull failure committed destination'
echo 'PASS: image pull failure leaves destination unused'

for failure in restore counts http business; do
  backup_fixture
  export FAIL=$failure; run_fail restore.sh "$BUNDLE" "$DEST"
  [[ -f $DEST/MIGRATION_FAILED && ! -f $DEST/MIGRATION_COMPLETE ]] || fail 'failed restore not marked'
  [[ $(cat "$SIM/running") == 0 ]] || fail 'failed target left running'
  cmp "$SOURCE/data/fixture" "$DEST/data/fixture" || fail 'failed restore deleted recovered data'
  echo "PASS: $failure failure pauses target and preserves recovery data"
done
echo "All $count isolated fixtures passed."
