#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
if [[ -f $STATE_DIR/current-image && $(cat "$STATE_DIR/current-image") != "$IMGBED_IMAGE" ]]; then
  die '已经安装过其他版本，请使用 update.sh'
fi
require_commands ss
if ss -H -ltn "sport = :$IMGBED_HOST_PORT" | grep -q . && [[ -z $(compose ps --status running -q imgbed) ]]; then
  die "本机端口 $IMGBED_HOST_PORT 已被占用"
fi
mkdir -p "$IMGBED_DATA_DIR"/{app,state,backups}
chmod 700 "$IMGBED_DATA_DIR" "$STATE_DIR" "$IMGBED_DATA_DIR/backups"
compose pull
digest=$(image_digest "$IMGBED_IMAGE")
set_config IMGBED_IMAGE "$digest"
target_started=false
completed=false
stop_failed_install() {
  local status=$?
  trap - EXIT
  if [[ $target_started == true && $completed != true ]]; then
    if ! compose stop imgbed; then
      printf '安装失败且无法确认应用已暂停，请立即检查容器状态。\n' >&2
    fi
    state_write failed-install "$IMGBED_IMAGE" || true
    status=1
  fi
  exit "$status"
}
trap stop_failed_install EXIT
target_started=true
compose up -d --wait --wait-timeout "$IMGBED_WAIT_SECONDS"
verify_http
record_release install
rm -f -- "$STATE_DIR/failed-install"
completed=true
printf '服务已在本机就绪。下一步：bash setup-nginx.sh，然后访问 https://%s 配置存储并验证上传、读取、删除。\n' "$IMGBED_DOMAIN"
printf '管理员密码仅保存在 .env；需要时在服务器本地查看。\n'
