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
was_running=$(compose ps --status running -q imgbed)
resume() {
  local status=$?
  trap - EXIT
  if [[ -n $was_running ]]; then
    if ! compose start --wait --wait-timeout "$IMGBED_WAIT_SECONDS" imgbed; then
      printf '应用恢复失败，请检查 compose 状态。\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap resume EXIT
compose stop imgbed
create_backup "$image"
