#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
require_commands ss
if [[ -f $TOONFLOW_DATA_DIR/state/current-image && $(cat "$TOONFLOW_DATA_DIR/state/current-image") != "$TOONFLOW_IMAGE" ]]; then
  die '已经安装过其他版本，请使用 update.sh'
fi
if ss -H -ltn "sport = :$TOONFLOW_HOST_PORT" | grep -q . && [[ -z $(compose ps --status running -q toonflow) ]]; then
  die "本机端口 $TOONFLOW_HOST_PORT 已被占用"
fi
compose pull toonflow
if [[ ! -d $TOONFLOW_DATA_DIR/app ]]; then
  # 绑定挂载不会复制镜像里的初始工作区，首次安装按实际镜像用户准备目录。
  app_uid=$(docker run --rm --network none --entrypoint id "$TOONFLOW_IMAGE" -u)
  app_gid=$(docker run --rm --network none --entrypoint id "$TOONFLOW_IMAGE" -g)
  [[ $app_uid =~ ^[0-9]+$ && $app_gid =~ ^[0-9]+$ ]] || die '无法读取镜像运行用户'
  mkdir -p "$TOONFLOW_DATA_DIR/app/workspaces/myProject"
  chown "$app_uid:$app_gid" "$TOONFLOW_DATA_DIR/app" "$TOONFLOW_DATA_DIR/app/workspaces" "$TOONFLOW_DATA_DIR/app/workspaces/myProject"
fi
mkdir -p "$TOONFLOW_DATA_DIR/state"
chmod 700 "$TOONFLOW_DATA_DIR" "$TOONFLOW_DATA_DIR/state"
if ! start_app; then
  compose stop toonflow || true
  die '启动失败，已尝试停止应用；请查看 docker compose logs --tail 100 toonflow'
fi
printf '%s\n' "$TOONFLOW_IMAGE" > "$TOONFLOW_DATA_DIR/state/current-image"
printf 'Toonflow 页面和工作区接口已就绪：127.0.0.1:%s。请通过 SSH 隧道访问并配置模型。\n' "$TOONFLOW_HOST_PORT"
