#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 ]] || die '用法：bash update.sh <新的个人镜像版本或摘要>'
validate_image "$1"
target=$1
lock_operation
load_env
check_docker
old=$(active_image)
validate_image "$old"
[[ -n $(compose ps --status running -q imgbed) ]] || die '应用未运行；请先处理上一次故障'
(export IMGBED_IMAGE="$target"; compose pull imgbed)
next=$(image_digest "$target")
if [[ $old == "$next" ]]; then printf '当前已经是目标镜像。\n'; exit 0; fi
begin_app_transaction "$next"
transaction_phase=paused
compose stop imgbed
create_backup "$old"
state_write previous-image "$old"
set_config IMGBED_IMAGE "$next"
transaction_phase='target-starting'
wait_app || die '新版本未通过健康检查，取消上线'
record_release update
rm -f -- "$STATE_DIR/failed-upgrade"
transaction_phase=complete
printf '升级完成：%s\n请验证认证、真实文件上传、读取、删除和存储渠道。备份：%s\n' "$next" "$BACKUP_PATH"
