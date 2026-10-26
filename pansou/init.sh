#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
require_commands openssl jq
lock_operation
[[ $# == 0 ]] || die '用法：sudo bash pansou/init.sh'
if [[ -e $ENV_FILE || -L $ENV_FILE ]]; then
  printf '.env 已存在，保留原配置与密钥。\n'
  exit 0
fi
temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
cp "$OPS_DIR/.env.example" "$temp"
sed -i "s|^AUTH_JWT_SECRET=.*|AUTH_JWT_SECRET=$(openssl rand -hex 32)|" "$temp"
sed -i "s|^CHANNELS=.*|CHANNELS=$(jq -r '.default_channels|join(",")' "$OPS_DIR/defaults.json")|" "$temp"
sed -i "s|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=$(jq -r '.enabled_plugins|join(",")' "$OPS_DIR/defaults.json")|" "$temp"
chmod 600 "$temp"
mv -- "$temp" "$ENV_FILE"
printf '已生成 .env 和 JWT 密钥。请在服务器本地填写 ADMIN_USERS、CERTBOT_EMAIL，再运行 install.sh。\n'
