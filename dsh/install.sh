#!/usr/bin/env bash
# 第 1 步：构建镜像并启动 dsh（只监听 127.0.0.1，外网访问由第 2 步的 nginx 负责）
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
load_env
command -v docker >/dev/null || { echo "没有找到 docker" >&2; exit 1; }

# 端口被别的程序占用就提前退出（自己已在运行的 dsh 容器除外）
if ss -tln | awk '{print $4}' | grep -qE "[:.]${DSH_HOST_PORT}\$" \
  && [ -z "$(docker compose ps --status running -q dsh 2>/dev/null)" ]; then
  echo "端口 ${DSH_HOST_PORT} 已被占用，请在 .env 里换一个 DSH_HOST_PORT" >&2
  exit 1
fi

# 数据目录：容器里以 node 用户（uid 1000）运行
mkdir -p "${DSH_DATA_DIR}/home" "${DSH_DATA_DIR}/workspace"
chown -R 1000:1000 "${DSH_DATA_DIR}"
chmod 750 "${DSH_DATA_DIR}"
fix_data_perms

echo "== 构建并启动 dsh ${DSH_VERSION}（第一次构建要下载依赖，几分钟）"
docker compose up -d --build

wait_ready
echo "下一步：./setup-nginx.sh"
