#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# -le 1 ]] || die '用法：bash backup.sh [--keep-stopped]'
keep_stopped=false
case "${1:-}" in
  '') ;;
  --keep-stopped) keep_stopped=true ;;
  *) die '用法：bash backup.sh [--keep-stopped]' ;;
esac
lock_operation
load_env
check_docker
image=$(active_image)
was_running=$(compose ps --status running -q imgbed)
backup_completed=false
resume() {
  local status=$?
  trap - EXIT
  if [[ -n $was_running && ( $keep_stopped == false || $backup_completed == false ) ]]; then
    if ! compose up -d --no-recreate --no-deps --pull never --wait --wait-timeout "$IMGBED_WAIT_SECONDS" imgbed; then
      printf '应用恢复失败，请检查 compose 状态。\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap resume EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
compose stop imgbed
create_backup "$image"
backup_completed=true
if [[ $keep_stopped == true ]]; then
  printf '迁移快照已完成，旧图床保持停止，避免转移期间产生新上传。\n'
fi
