#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
running=$(compose ps --status running -q toonflow)
finish() {
  local result=$?
  trap - EXIT
  if [[ -n $running ]] && ! resume_app; then
    printf '备份后恢复服务失败，请检查 Toonflow 容器。\n' >&2
    result=1
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -z $running ]] || compose stop toonflow
create_backup
printf '备份完成：%s（包含项目、素材、插件和模型密钥，请妥善保存）\n' "$BACKUP_PATH"
