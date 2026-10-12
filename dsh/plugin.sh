#!/usr/bin/env bash
# 管理 dsh 插件：在容器里运行 `dsh plugin --profile web ...`，装好后重启 dsh 让插件生效。
# 插件装在 <数据目录>/home/profiles/web，升级、重建镜像都不受影响。
# 用法：./plugin.sh add dshmarket    ./plugin.sh remove dshmarket    ./plugin.sh list
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
load_env

if [ $# -eq 0 ]; then
  sed -n '4p' "$0" | sed 's/^# //'
  exit 1
fi
if [ -z "$(docker compose ps --status running -q dsh 2>/dev/null)" ]; then
  echo "dsh 没有在运行，先 ./install.sh 或 ./update.sh" >&2
  exit 1
fi

docker compose exec -T dsh dsh plugin --profile web "$@"

case "$1" in
  add|remove|rm|uninstall|update|up|upgrade|allow-version)
    echo "== 重启 dsh 让插件生效"
    docker compose restart dsh >/dev/null
    wait_ready
    echo "如果浏览器要求重新登录，运行 ./login-url.sh"
    ;;
esac
