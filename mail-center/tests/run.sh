#!/usr/bin/env bash
set -euo pipefail
TEST_SOURCE=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for script in "$TEST_SOURCE"/*.sh "$TEST_SOURCE"/smtp/*.sh; do bash -n "$script"; done
mkdir -p "$TEST_ROOT/project" "$TEST_ROOT/bin"
cp "$TEST_SOURCE/lib.sh" "$TEST_SOURCE/init.sh" "$TEST_SOURCE/install.sh" "$TEST_SOURCE/restore.sh" "$TEST_ROOT/project/"
cat > "$TEST_ROOT/bin/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
chmod +x "$TEST_ROOT/bin/id"
export PATH="$TEST_ROOT/bin:$PATH"
config="$TEST_ROOT/project/.env"
cat > "$config" <<'EOF'
MAIL_CENTER_PROJECT=mail-center-regression
MAIL_CENTER_VERSION=2026.10.28-1
MAIL_CENTER_API_IMAGE=ghcr.io/haipengtian/mail-center:v0.1.0
MAIL_CENTER_WEB_IMAGE=ghcr.io/haipengtian/mail-center-ui:v0.1.0
MAIL_CENTER_SMTP_IMAGE=ghcr.io/haipengtian/mail-center-smtp:v0.1.0
MAIL_DOMAIN=mail.example.com
RECEIVE_DOMAIN=inbox.example.com
MX_HOSTNAME=mx.example.com
MAIL_CENTER_PORT=13013
POSTGRES_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
MAIL_CENTER_ENV_FILE=$config bash -c 'source "$1/lib.sh"; load_env; [[ $MAIL_DOMAIN == mail.example.com ]]' _ "$TEST_ROOT/project" || fail 'valid config rejected'
cp "$config" "$TEST_ROOT/original"
if result=$(bash "$TEST_ROOT/project/init.sh" mail.example.com inbox.example.com mx.example.com 2>&1); then fail 'existing configuration overwritten'; fi
[[ $result == *'.env 已存在'* ]] || fail 'initialization failed for an unexpected reason'
cmp "$config" "$TEST_ROOT/original" || fail 'initialization changed existing configuration'
printf 'MAIL_DOMAIN=$(touch %s)\n' "$TEST_ROOT/injected" >> "$config"
if MAIL_CENTER_ENV_FILE=$config bash -c 'source "$1/lib.sh"; load_env' _ "$TEST_ROOT/project" >/dev/null 2>&1; then fail 'invalid domain accepted'; fi
[[ ! -e $TEST_ROOT/injected ]] || fail 'dotenv command substitution executed'
cp "$TEST_ROOT/original" "$config"
touch "$TEST_ROOT/fake-backup.tar.gz"
if result=$(bash "$TEST_ROOT/project/restore.sh" "$TEST_ROOT/fake-backup.tar.gz" 2>&1); then fail 'restore allowed existing installation'; fi
[[ $result == *'全新部署目录'* ]] || fail 'restore failed for an unexpected reason'
cmp "$config" "$TEST_ROOT/original" || fail 'restore changed existing configuration'
for image in ghcr.io/haipengtian/mail-center:v0.1.0 ghcr.io/haipengtian/mail-center:sha-0123456789ab ghcr.io/haipengtian/mail-center@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  bash -c 'source "$1/lib.sh"; validate_image "$2"' _ "$TEST_ROOT/project" "$image" || fail 'fixed GHCR image rejected'
done
for image in ghcr.io/haipengtian/mail-center:latest ghcr.io/haipengtian/mail-center ghcr.io/haipengtian/mail-center:main local-build:v0.1.0; do
  if bash -c 'source "$1/lib.sh"; validate_image "$2"' _ "$TEST_ROOT/project" "$image" >/dev/null 2>&1; then fail 'rolling or local image accepted'; fi
done
if grep -Eq '^[[:space:]]+build:' "$TEST_SOURCE/compose.yaml"; then fail 'production compose still builds on the server'; fi
cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_TEST_CALLS"
if [[ $* == *' pull '* && ${DOCKER_TEST_PULL_FAIL:-} == 1 ]]; then exit 42; fi
EOF
chmod +x "$TEST_ROOT/bin/docker"
export DOCKER_TEST_CALLS="$TEST_ROOT/docker-calls"
if DOCKER_TEST_PULL_FAIL=1 bash "$TEST_ROOT/project/install.sh" >/dev/null 2>&1; then fail 'failed pull did not stop installation'; fi
if grep -Eq '(^| )up( |$)' "$DOCKER_TEST_CALLS"; then fail 'started services after failed pull'; fi
: > "$DOCKER_TEST_CALLS"
bash "$TEST_ROOT/project/install.sh" >/dev/null
grep -Fq 'pull postgres api web gateway' "$DOCKER_TEST_CALLS" || fail 'missing image pull'
grep -Fq 'up -d --no-build --pull never --wait' "$DOCKER_TEST_CALLS" || fail 'startup can build or fetch different images'
if grep -Eq '(^| )build( |$)' "$DOCKER_TEST_CALLS"; then fail 'installation called docker build'; fi
printf 'Deployment regression checks passed.\n'
