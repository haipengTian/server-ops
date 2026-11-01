#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
load_env
compose ps
printf '配置镜像：%s\n访问地址：127.0.0.1:%s\n数据目录：%s/app\n' "$TOONFLOW_IMAGE" "$TOONFLOW_HOST_PORT" "$TOONFLOW_DATA_DIR"
for name in current-image previous-image last-backup; do
  [[ ! -f $TOONFLOW_DATA_DIR/state/$name ]] || printf '%s：%s\n' "$name" "$(cat "$TOONFLOW_DATA_DIR/state/$name")"
done
