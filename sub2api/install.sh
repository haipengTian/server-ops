#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
if [[ -f $STATE_DIR/current-image && $(cat "$STATE_DIR/current-image") != "$SUB2API_IMAGE" ]]; then
  die '已经安装过其他版本，请使用 update.sh'
fi
require_commands ss
if ss -H -ltn "sport = :$SUB2API_HOST_PORT" | grep -q . && [[ -z $(compose ps --status running -q sub2api) ]]; then
  die "本机端口 $SUB2API_HOST_PORT 已被占用"
fi
mkdir -p "$SUB2API_DATA_DIR"/{app,postgres,redis,state,backups}
chmod 700 "$SUB2API_DATA_DIR" "$STATE_DIR" "$SUB2API_DATA_DIR/backups"
compose pull
digest=$(image_digest "$SUB2API_IMAGE")
set_config SUB2API_IMAGE "$digest"
compose up -d --wait --wait-timeout "$SUB2API_WAIT_SECONDS"
curl --fail --silent --show-error --connect-timeout 5 --max-time 15 "http://127.0.0.1:$SUB2API_HOST_PORT/health" >/dev/null
record_release install
printf '服务已在本机就绪。下一步：bash setup-nginx.sh，然后访问 https://%s 完成实际网关验收。\n' "$SUB2API_DOMAIN"
printf '管理员密码仅保存在 .env；需要时在服务器本地查看。\n'
