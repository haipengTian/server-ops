#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
require_commands tar
[[ -d $PANSOU_DATA_DIR/app && ! -L $PANSOU_DATA_DIR/app ]] || die '应用数据目录不存在或为符号链接'
running=$(compose ps --status running -q pansou)
resume() {
  local status=$?
  trap - EXIT
  if [[ -n $running ]]; then
    if ! compose start --wait --wait-timeout "$PANSOU_WAIT_SECONDS" pansou; then
      printf '备份后恢复服务失败，请检查 PanSou 容器。\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap resume EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -z $running ]] || compose stop pansou
mkdir -p "$PANSOU_DATA_DIR/backups"
chmod 700 "$PANSOU_DATA_DIR/backups"
backup=$(mktemp -d "$PANSOU_DATA_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
tar -czf "$backup/data.tar.gz" -C "$PANSOU_DATA_DIR/app" .
tar -tzf "$backup/data.tar.gz" >/dev/null
cp "$ENV_FILE" "$backup/deployment.env"
cp "$OPS_DIR/docker-compose.yml" "$backup/docker-compose.yml"
touch "$backup/COMPLETE"
printf '备份完成：%s（含账号、配置和密钥，请妥善保存）\n' "$backup"
