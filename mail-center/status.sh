#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
load_env
compose --profile smtp ps
curl -fsS "http://127.0.0.1:$MAIL_CENTER_PORT/healthz"
printf '\n'
curl -fsS "http://127.0.0.1:$MAIL_CENTER_PORT/api/v1/auth/status"
printf '\n'
