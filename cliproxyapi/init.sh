#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
require_commands openssl awk sed realpath chown
lock_operation
[[ $# == 1 ]] || die '用法：bash init.sh ghcr.io/haipengtian/cliproxyapi:<固定 custom 版本或摘要>'
validate_image "$1"
if [[ ! -e $ENV_FILE ]]; then
  temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
  trap 'rm -f -- "$temp"' EXIT
  sed "s|^CLIPROXY_IMAGE=$|CLIPROXY_IMAGE=$1|" "$OPS_DIR/.env.example" > "$temp"
  chmod 600 "$temp"
  mv -- "$temp" "$ENV_FILE"
fi
load_env
ensure_layout
config="$CLIPROXY_DATA_DIR/config/config.yaml"
keys="$CLIPROXY_DATA_DIR/secrets/initial-keys"
if [[ -f $config ]]; then
  printf '已有配置与账号保持不变；升级请使用 update.sh。\n'
  exit 0
fi
[[ ! -e $keys ]] || die '初始化中断且初始密钥已存在；保留现场，检查配置备份后处理，不能重新生成密钥'
management_key=$(openssl rand -hex 32)
client_key=$(openssl rand -hex 32)
printf 'MANAGEMENT_KEY=%s\nCLIENT_API_KEY=%s\n' "$management_key" "$client_key" > "$keys"
chmod 600 "$keys"
temp=$(mktemp "$CLIPROXY_DATA_DIR/config/.config.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
sed -e "s/__MANAGEMENT_KEY__/$management_key/" -e "s/__CLIENT_API_KEY__/$client_key/" \
  -e "s/__TRUSTED_PROXY__/$CLIPROXY_GATEWAY/" "$OPS_DIR/config.example.yaml" > "$temp"
chmod 600 "$temp"
chown 10001:10001 "$temp"
mv -- "$temp" "$config"
printf '配置已生成。请填写 .env 中的 CERTBOT_EMAIL，核对资源与网络后运行 bash install.sh。\n'
printf '登录密钥只保存在服务器的 %s，脚本不打印密钥。\n' "$keys"
