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
[[ -n $(compose ps --status running -q cliproxyapi) ]] || die '应用未运行；请先处理上一次故障'
(export CLIPROXY_IMAGE="$target"; compose pull cliproxyapi)
next=$(image_digest "$target")
if [[ $old == "$next" ]]; then printf '当前已经是目标镜像。\n'; exit 0; fi
begin_app_transaction "$next"
transaction_phase=paused
compose stop cliproxyapi
create_backup "$old"
state_write previous-image "$old"
set_config CLIPROXY_IMAGE "$next"
transaction_phase='target-starting'
wait_app || die '新版本未通过健康检查，取消上线'
record_release update
rm -f -- "$STATE_DIR/failed-upgrade"
transaction_phase=complete
printf '升级完成：%s\n请验证管理登录、账号接入、真实模型与流式调用。备份：%s\n' "$next" "$BACKUP_PATH"
