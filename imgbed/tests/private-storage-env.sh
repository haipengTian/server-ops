#!/usr/bin/env bash
# Only parses synthetic files. Does not invoke Docker or touch application data.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/imgbed-private-env-XXXXXXXX")
trap 'rm -f -- "$work/deployment.env"; rmdir -- "$work"' EXIT
sed -e 's|^IMGBED_IMAGE=.*|IMGBED_IMAGE=ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.1|' \
    -e 's|^BASIC_PASS=.*|BASIC_PASS=synthetic-password|' \
    -e 's|^AUTH_CODE=.*|AUTH_CODE=synthetic-upload-password|' \
    -e 's|^AI_CONFIG_SECRET=.*|AI_CONFIG_SECRET=synthetic-key|' \
    -e '/^IMGBED_PRIVATE_STORAGE_CHANNELS=/d' "$ROOT/.env.example" > "$work/deployment.env"
(
    source "$ROOT/lib.sh"
    ENV_FILE="$work/deployment.env"
    export IMGBED_PRIVATE_STORAGE_CHANNELS='s3:unexpected-inherited-setting'
    load_env
    [[ ${IMGBED_PRIVATE_STORAGE_CHANNELS:-} == '' ]]
) || { echo 'Legacy deployment must keep private storage disabled' >&2; exit 1; }
printf 'IMGBED_PRIVATE_STORAGE_CHANNELS=cfr2:R2_env,s3:cloudreve_private\n' >> "$work/deployment.env"
(
    source "$ROOT/lib.sh"
    ENV_FILE="$work/deployment.env"
    load_env
    [[ $IMGBED_PRIVATE_STORAGE_CHANNELS == 'cfr2:R2_env,s3:cloudreve_private' ]]
) || { echo 'Explicit private channels must pass the shared deployment parser' >&2; exit 1; }
echo 'PASS: legacy config stays disabled; private channel allowlist is accepted'
