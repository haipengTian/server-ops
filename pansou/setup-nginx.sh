#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
[[ -n $CERTBOT_EMAIL ]] || die '请在 .env 填写 CERTBOT_EMAIL'
verify_http
exec bash "$OPS_DIR/../nginx/add-site.sh" --domain "$PANSOU_DOMAIN" \
  --upstream "http://127.0.0.1:$PANSOU_HOST_PORT" --email "$CERTBOT_EMAIL"
