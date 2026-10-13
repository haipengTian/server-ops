#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
require_commands openssl awk
lock_operation
[[ $# == 1 ]] || die '用法：bash init.sh ghcr.io/haipengtian/cloudflare-imgbed:<固定 custom 版本或摘要>'
validate_image "$1"
if [[ -e $ENV_FILE ]]; then
  printf '.env 已存在，保留原配置与密钥。申请证书前请填写 CERTBOT_EMAIL。\n'
  exit 0
fi
temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
cp "$OPS_DIR/.env.example" "$temp"
for key in BASIC_PASS AUTH_CODE AI_CONFIG_SECRET; do
  secret=$(openssl rand -hex 32)
  # 只处理模板中的已知空值，不打印生成的密钥。
  sed -i "s/^${key}=\$/${key}=${secret}/" "$temp"
done
sed -i "s|^IMGBED_IMAGE=\$|IMGBED_IMAGE=$1|" "$temp"
chmod 600 "$temp"
mv -- "$temp" "$ENV_FILE"
printf '已生成服务器本地 .env。请填写 CERTBOT_EMAIL，核对资源上限，然后运行 bash install.sh。\n'
