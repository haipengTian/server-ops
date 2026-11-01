#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 ]] || die '用法：bash init.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.1'
validate_image "$1"
lock_operation
if [[ -e $ENV_FILE || -L $ENV_FILE ]]; then
  printf '.env 已存在，保留原配置。\n'
  exit 0
fi
temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
sed "s|^TOONFLOW_IMAGE=.*|TOONFLOW_IMAGE=$1|" "$OPS_DIR/.env.example" > "$temp"
chmod 600 "$temp"
mv -- "$temp" "$ENV_FILE"
printf '已生成 .env。核对端口、数据目录和资源上限后运行 bash install.sh。\n'
