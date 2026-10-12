#!/usr/bin/env bash
# 升级：先在 .env 里改 DSH_VERSION（看过新版本的更新说明再改），再运行本脚本。
# 数据在 DSH_DATA_DIR 里，不受影响。
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
git -C .. pull --ff-only || echo "（git pull 失败，继续用本地文件）"
load_env

echo "== 用 DSH_VERSION=${DSH_VERSION} 重新构建并启动"
docker compose up -d --build
docker image prune -f >/dev/null

wait_ready
echo "容器已重启，登录网址会变化：./login-url.sh"
