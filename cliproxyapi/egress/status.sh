#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=../lib.sh
source "$(dirname -- "$0")/../lib.sh"
require_root
load_env
export EGRESS_NETWORK_NAME="${COMPOSE_PROJECT_NAME}_backend"
require_commands docker
docker compose --env-file "$ENV_FILE" -f "$OPS_DIR/egress/compose.yml" \
  -p "${COMPOSE_PROJECT_NAME}-egress" ps
# Test from the actual application container, with remote DNS through SOCKS5.
compose exec -T cliproxyapi curl --fail --silent --show-error \
  --noproxy '' --proxy socks5h://cliproxyapi-egress:1080 \
  --retry 3 --retry-delay 1 --retry-connrefused --retry-max-time 40 \
  --connect-timeout 8 --max-time 12 https://ipinfo.io/json
printf '\n容器内代理地址：socks5://cliproxyapi-egress:1080\n'
