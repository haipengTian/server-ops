#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 ]] || die '用法：bash update.sh <新的个人镜像固定版本或摘要>'
validate_image "$1"
target=$1
lock_operation
load_env
check_docker
[[ -n $(compose ps --status running -q toonflow) ]] || die '应用未运行，请先处理当前故障'
old=$TOONFLOW_IMAGE
[[ ! -f $TOONFLOW_DATA_DIR/state/current-image || $(cat "$TOONFLOW_DATA_DIR/state/current-image") == "$old" ]] || die '配置镜像与已记录版本不同，请先核对部署状态'
if [[ $target == "$old" ]]; then printf '当前已经是目标版本。\n'; exit 0; fi
(export TOONFLOW_IMAGE="$target"; compose pull toonflow)
target_started=false
completed=false
finish() {
  local result=$?
  trap - EXIT
  if [[ $completed != true ]]; then
    if [[ $target_started == true ]]; then
      compose stop toonflow || printf '无法确认新容器已停止，请立即检查。\n' >&2
      printf '升级失败。升级前备份：%s\n保留新版本数据，请按 README 的恢复步骤处理。\n' "${BACKUP_PATH:-未生成}" >&2
    elif ! resume_app; then
      printf '未切换版本，但恢复原容器失败，请检查。\n' >&2
    fi
    result=1
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
compose stop toonflow
create_backup
printf '%s\n' "$old" > "$TOONFLOW_DATA_DIR/state/previous-image"
set_image "$target"
target_started=true
start_app
printf '%s\n' "$target" > "$TOONFLOW_DATA_DIR/state/current-image"
completed=true
printf '升级完成：%s\n升级前备份：%s\n请验证原项目、素材和一次真实模型生成。\n' "$target" "$BACKUP_PATH"
