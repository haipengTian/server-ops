#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/cloudreve-ops-test.XXXXXX)
[[ $(realpath -m -- "$scratch") == /tmp/cloudreve-ops-test.* ]] || exit 1
trap 'rm -rf -- "$scratch"' EXIT
export MOCK_STATE="$scratch/mock" REAL_TAR
REAL_TAR=$(command -v tar)
mkdir -p "$MOCK_STATE" "$scratch/bin" "$scratch/ops"
cp "$source_dir"/*.sh "$source_dir/compose.yaml" "$source_dir/.env.example" "$scratch/ops/"
sed -e "s|/opt/cloudreve|$scratch/storage|g" "$source_dir/.env.example" > "$scratch/ops/.env"
cat > "$scratch/bin/id" <<'EOF'
#!/usr/bin/env bash
echo 0
EOF
cat > "$scratch/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scratch/bin/chown" <<'EOF'
#!/usr/bin/env bash
# Only the real installer changes ownership; test files remain caller-owned.
[[ $1 == 0:0 ]] || exit 1
EOF
cat > "$scratch/bin/tar" <<'EOF'
#!/usr/bin/env bash
[[ ${MOCK_TAR_FAIL:-0} == 0 ]] || exit 2
exec "$REAL_TAR" "$@"
EOF
cat > "$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_STATE/log"
case "$1" in
  info) exit 0 ;;
  image)
    if [[ $3 == *custom.2 ]]; then ch=b; else ch=a; fi
    printf 'ghcr.io/haipengtian/cloudreve@sha256:%064d\n' 0 | tr 0 "$ch"
    exit 0 ;;
  inspect)
    if [[ $3 == *Config.Image* ]]; then cat "$MOCK_STATE/image";
    elif [[ -f $MOCK_STATE/running ]]; then echo true; else echo false; fi
    exit 0 ;;
  compose) shift ;;
  *) exit 1 ;;
esac
while (($#)); do
  case "$1" in --project-directory|--env-file|-f|-p) shift 2 ;; *) break ;; esac
done
case "$1" in
  config|logs) ;;
  ps) [[ ! -f $MOCK_STATE/exists ]] || echo mock-container ;;
  pull) [[ ${MOCK_PULL_FAIL:-0} == 0 ]] ;;
  stop) rm -f "$MOCK_STATE/running" ;;
  start) touch "$MOCK_STATE/running" ;;
  up)
    touch "$MOCK_STATE/exists" "$MOCK_STATE/running"
    echo "$CLOUDREVE_IMAGE" > "$MOCK_STATE/image"
    [[ ${MOCK_HEALTH_FAIL:-0} == 0 ]]
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"
cd "$scratch/ops"
bash install.sh >/dev/null
[[ -f $MOCK_STATE/running ]] || exit 1
echo original > "$scratch/storage/data/example.txt"
if bash install.sh >/dev/null 2>&1; then echo 'reinstall unexpectedly allowed' >&2; exit 1; fi
before=$(cat "$MOCK_STATE/image")
if MOCK_PULL_FAIL=1 bash update.sh ghcr.io/haipengtian/cloudreve:4.19.1-custom.2 >/dev/null 2>&1; then exit 1; fi
[[ -f $MOCK_STATE/running && $(cat "$MOCK_STATE/image") == "$before" ]] || exit 1
if MOCK_TAR_FAIL=1 bash update.sh ghcr.io/haipengtian/cloudreve:4.19.1-custom.2 >/dev/null 2>&1; then exit 1; fi
[[ -f $MOCK_STATE/running && $(cat "$MOCK_STATE/image") == "$before" ]] || exit 1
if MOCK_HEALTH_FAIL=1 bash update.sh ghcr.io/haipengtian/cloudreve:4.19.1-custom.2 >/dev/null 2>&1; then exit 1; fi
[[ ! -f $MOCK_STATE/running ]] || exit 1
backup=$(find "$scratch/storage/backups" -name image-ref -print | head -1)
[[ -n $backup ]] || exit 1
echo new-after-failure > "$scratch/storage/data/new.txt"
bash restore.sh "$(dirname "$backup")" >/dev/null
restored=$(sed -n 's/^CLOUDREVE_DATA_DIR=//p' .env)
[[ $restored != "$scratch/storage/data" && -f $MOCK_STATE/running ]] || exit 1
[[ $(cat "$restored/example.txt") == original && ! -e $restored/new.txt ]] || exit 1
[[ -e $scratch/storage/data/new.txt && $(cat "$MOCK_STATE/image") == "$before" ]] || exit 1
bash backup.sh >/dev/null
bash update.sh ghcr.io/haipengtian/cloudreve:4.19.1-custom.2 >/dev/null
[[ $(cat "$MOCK_STATE/image") != "$before" && -f $MOCK_STATE/running ]] || exit 1
echo 'Passed: fresh install, reinstall rejection, pull/backup failure, failed-health pause, isolated restore, backup and successful update.'
