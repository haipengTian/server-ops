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
was_running=$(compose ps --status running -q sub2api)
resume() {
  local status=$?
  trap - EXIT
  if [[ -n $was_running ]]; then
    if ! compose start --wait --wait-timeout "$SUB2API_WAIT_SECONDS" sub2api; then
      printf '应用恢复失败，请检查 compose 状态。\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap resume EXIT
compose stop sub2api
create_backup "$image"
