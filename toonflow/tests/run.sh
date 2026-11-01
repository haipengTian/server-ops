#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/toonflow-tests-XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/ops" "$scratch/bin" "$scratch/data/app/workspaces/myProject"
cp "$root/"*.sh "$root/.env.example" "$root/docker-compose.yml" "$scratch/ops/"
cat > "$scratch/bin/id" <<'STUB'
#!/usr/bin/env bash
echo 0
STUB
cat > "$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == info ]]; then exit 0; fi
if [[ $1 == run ]]; then
  /usr/bin/id "${@: -1}"
  exit 0
fi
[[ $1 == compose ]] || exit 92
shift
while [[ $1 == --* || $1 == -f ]]; do shift 2; done
cmd=$1; shift
printf '%s %s\n' "$cmd" "$*" >> "$events"
case "$cmd" in
  version|config|stop) exit 0 ;;
  ps) echo running-container ;;
  pull) [[ ${failure:-} != pull ]] ;;
  up)
    [[ " $* " != *' --no-recreate '* && ${failure:-} == startup ]] && exit 1
    exit 0 ;;
  exec) exit 0 ;;
  *) exit 93 ;;
esac
STUB
chmod +x "$scratch/bin/"*
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/bin/ss"
chmod +x "$scratch/bin/ss"
export PATH="$scratch/bin:$PATH"
export events="$scratch/events" failure=
ops="$scratch/ops"
image=ghcr.io/haipengtian/toonflow:2.0.9-custom.1
bash "$ops/init.sh" "$image"
sed -i "s|^TOONFLOW_DATA_DIR=.*|TOONFLOW_DATA_DIR=$scratch/data|" "$ops/.env"
cp "$ops/.env" "$scratch/original.env"
bash "$ops/init.sh" ghcr.io/haipengtian/toonflow:2.0.9-custom.2
cmp "$ops/.env" "$scratch/original.env"
[[ $(stat -c %a "$ops/.env") == 600 ]]
echo 'PASS: initialization preserves configuration and mode 600'

if bash "$ops/install.sh" > "$scratch/output" 2>&1; then
  echo 'FAIL: install accepted missing auth configuration' >&2; exit 1
fi
sed -i "s|^TOONFLOW_AUTH_PASSWORD_HASH=.*|TOONFLOW_AUTH_PASSWORD_HASH=$(printf '%064d:%0128d' 0 0)|" "$ops/.env"
cp "$ops/.env" "$scratch/original.env"
echo 'PASS: install refuses to run without administrator authentication'

for invalid in ghcr.io/haipengtian/toonflow:latest ghcr.io/other/toonflow:2.0.9-custom.1; do
  : > "$events"
  if bash "$ops/update.sh" "$invalid" > "$scratch/output" 2>&1; then
    echo 'FAIL: invalid image accepted' >&2; exit 1
  fi
  [[ ! -s $events ]]
done
echo 'PASS: invalid image references rejected before Docker operations'

# shellcheck disable=SC2016
printf 'TOONFLOW_DATA_DIR=$(touch %s/injected)\n' "$scratch" >> "$ops/.env"
if bash "$ops/status.sh" > "$scratch/output" 2>&1; then
  echo 'FAIL: unsafe configuration accepted' >&2; exit 1
fi
[[ ! -e $scratch/injected ]]
cp "$scratch/original.env" "$ops/.env"
echo 'PASS: configuration is never executed as shell'

sed -i "s|^TOONFLOW_DATA_DIR=.*|TOONFLOW_DATA_DIR=$scratch/fresh|" "$ops/.env"
bash "$ops/install.sh"
[[ -d $scratch/fresh/app/workspaces/myProject ]]
[[ $(stat -c %u "$scratch/fresh/app") == "$(/usr/bin/id -u)" ]]
[[ $(cat "$scratch/fresh/state/current-image") == "$image" ]]
cp "$scratch/original.env" "$ops/.env"
echo 'PASS: first install creates the initial workspace owned by the image user'

printf 'retained-project\n' > "$scratch/data/app/workspaces/myProject/story.json"
bash "$ops/backup.sh"
backup=$(cat "$scratch/data/state/last-backup")
[[ -f $backup/COMPLETE ]]
tar -xOf "$backup/data.tar.gz" ./workspaces/myProject/story.json | cmp - "$scratch/data/app/workspaces/myProject/story.json"
cmp "$backup/deployment.env" "$ops/.env"
grep -q '^up .*--no-recreate' "$events"
echo 'PASS: backup contains real project files and resumes the existing container'

: > "$events"
export failure=pull
if bash "$ops/update.sh" ghcr.io/haipengtian/toonflow:2.0.9-custom.2 > "$scratch/output" 2>&1; then exit 1; fi
if grep -q '^stop ' "$events"; then echo 'FAIL: pull failure stopped service' >&2; exit 1; fi
cmp "$ops/.env" "$scratch/original.env"
echo 'PASS: image pull failure leaves service and configuration unchanged'

: > "$events"
export failure=startup
if bash "$ops/update.sh" ghcr.io/haipengtian/toonflow:2.0.9-custom.2 > "$scratch/output" 2>&1; then exit 1; fi
[[ $(grep -c '^stop ' "$events") -ge 2 ]]
[[ -f $(cat "$scratch/data/state/last-backup")/COMPLETE ]]
[[ $(cat "$scratch/data/app/workspaces/myProject/story.json") == retained-project ]]
grep -q '^TOONFLOW_IMAGE=ghcr.io/haipengtian/toonflow:2.0.9-custom.2$' "$ops/.env"
echo 'PASS: failed upgrade stops the target and preserves data and pre-upgrade backup'

cp "$scratch/original.env" "$ops/.env"
export failure=
bash "$ops/update.sh" ghcr.io/haipengtian/toonflow:2.0.9-custom.2
[[ $(cat "$scratch/data/state/current-image") == ghcr.io/haipengtian/toonflow:2.0.9-custom.2 ]]
[[ $(cat "$scratch/data/state/previous-image") == "$image" ]]
echo 'PASS: successful upgrade records the new and previous image'

sed -i 's|^TOONFLOW_AUTH_ENABLED=.*|TOONFLOW_AUTH_ENABLED=false|' "$ops/.env"
if bash "$ops/setup-nginx.sh" admin@example.com > "$scratch/output" 2>&1; then exit 1; fi
grep -q '开启登录鉴权' "$scratch/output"
cp "$scratch/original.env" "$ops/.env"

cat > "$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ $* == *'/api/auth/session'* ]]; then
  printf '{"code":200,"data":{"enabled":%s,"authenticated":false}}' "${auth_enabled:-false}"
elif [[ $* == *'/login'* ]]; then
  echo '<form action="/api/auth/login">'
else
  printf '%s' "${anonymous_code:-200}"
fi
STUB
chmod +x "$scratch/bin/curl"
if bash "$ops/setup-nginx.sh" admin@example.com > "$scratch/output" 2>&1; then exit 1; fi
grep -q '未启用登录鉴权' "$scratch/output"
export auth_enabled=true anonymous_code=200
if bash "$ops/setup-nginx.sh" admin@example.com > "$scratch/output" 2>&1; then exit 1; fi
grep -q '匿名接口' "$scratch/output"
echo 'PASS: public setup rejects disabled auth, old unprotected images and exposed business APIs'
