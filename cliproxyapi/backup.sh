#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
image=$(active_image)
was_running=$(compose ps --status running -q cliproxyapi)
resume() {
  local status=$?
  trap - EXIT
  if [[ -n $was_running ]]; then
    if ! compose up -d --no-recreate --no-deps --pull never --wait --wait-timeout "$CLIPROXY_WAIT_SECONDS" cliproxyapi; then
      printf '应用恢复失败，请检查 compose 状态。\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap resume EXIT
compose stop cliproxyapi
create_backup "$image"
