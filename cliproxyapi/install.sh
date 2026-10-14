#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
if [[ -f $STATE_DIR/current-image && $(cat "$STATE_DIR/current-image") != "$CLIPROXY_IMAGE" ]]; then
  die '已经安装过其他版本，请使用 update.sh'
fi
require_commands ss
if ss -H -ltn "sport = :$CLIPROXY_HOST_PORT" | grep -q . && [[ -z $(compose ps --status running -q cliproxyapi) ]]; then
  die "本机端口 $CLIPROXY_HOST_PORT 已被占用"
fi
ensure_layout
[[ -f $CLIPROXY_DATA_DIR/config/config.yaml ]] || die '先运行 init.sh 生成配置'
compose pull
digest=$(image_digest "$CLIPROXY_IMAGE")
set_config CLIPROXY_IMAGE "$digest"
target_started=false
completed=false
stop_failed_install() {
  local status=$?
  trap - EXIT
  if [[ $target_started == true && $completed != true ]]; then
    if ! compose stop cliproxyapi; then
      printf '安装失败且无法确认应用已暂停，请立即检查容器状态。\n' >&2
    fi
    state_write failed-install "$CLIPROXY_IMAGE" || true
    status=1
  fi
  exit "$status"
}
trap stop_failed_install EXIT
target_started=true
compose up -d --wait --wait-timeout "$CLIPROXY_WAIT_SECONDS"
verify_http
record_release install
rm -f -- "$STATE_DIR/failed-install"
completed=true
printf '服务已在本机就绪。下一步：bash setup-nginx.sh，然后访问 https://%s/management.html 接入账号并验证真实调用。\n' "$CLIPROXY_DOMAIN"
printf '初始密钥仅保存在数据目录 secrets/initial-keys；需要时在服务器本地查看。\n'
