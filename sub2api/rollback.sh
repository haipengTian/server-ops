#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 && $1 == --database-compatible ]] || die '确认数据库向后兼容后执行：bash rollback.sh --database-compatible；不兼容时按 README 恢复备份'
lock_operation
load_env
check_docker
[[ -f $STATE_DIR/previous-image ]] || die '没有可回滚的上一版本'
previous=$(cat "$STATE_DIR/previous-image")
validate_image "$previous"
current=$(active_image)
validate_image "$current"
(export SUB2API_IMAGE="$previous"; compose pull sub2api)
begin_app_transaction "$previous"
transaction_phase=paused
compose stop sub2api
# 保留回滚前的数据库与配置，不覆盖升级前备份。
create_backup "$current"
set_config SUB2API_IMAGE "$previous"
transaction_phase='target-starting'
wait_app || die '旧版本未通过检查，请根据备份处理'
record_release rollback
rm -f -- "$STATE_DIR/failed-upgrade"
transaction_phase=complete
printf '应用已回滚到 %s；请完成真实请求与计费验收。\n' "$previous"
