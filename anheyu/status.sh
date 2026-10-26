#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# -le 1 ]] || die '用法：sudo bash anheyu/status.sh [/opt/anheyu]'
check_docker
DEPLOY_ROOT=$(realpath -e -- "${1:-/opt/anheyu}")
ENV_FILE="$DEPLOY_ROOT/.env"
COMPOSE_FILE="$DEPLOY_ROOT/docker-compose.prod.yml"
IMAGES_FILE=
if [[ -f $DEPLOY_ROOT/docker-compose.images.yml ]]; then IMAGES_FILE="$DEPLOY_ROOT/docker-compose.images.yml"; fi
compose ps -a
for marker in MIGRATION_FAILED MIGRATION_COMPLETE; do
  if [[ -f $DEPLOY_ROOT/$marker ]]; then printf '%s\n' "$marker"; fi
done
if [[ -f $DEPLOY_ROOT/counts-restored.tsv ]]; then cat "$DEPLOY_ROOT/counts-restored.tsv"; fi
