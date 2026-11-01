#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
require_commands docker
username=${1:-${TOONFLOW_AUTH_USERNAME:-admin}}
origin=${2:-${TOONFLOW_PUBLIC_ORIGIN:-https://toonflow.thpvip.xyz}}
[[ $# -le 2 && $username =~ ^[a-zA-Z0-9@._-]{1,64}$ ]] || die '用法：bash setup-auth.sh [管理员用户名] [https://域名]'
export TOONFLOW_AUTH_ENABLED=true TOONFLOW_AUTH_USERNAME="$username" TOONFLOW_PUBLIC_ORIGIN="$origin"
# 使用固定格式占位摘要，只在内存中校验域名和用户名；不会保存占位值。
export TOONFLOW_AUTH_PASSWORD_HASH
TOONFLOW_AUTH_PASSWORD_HASH=$(printf '%064d:%0128d' 0 0)
require_auth
[[ -t 0 ]] || die '请在服务器交互式终端运行，密码不会显示或写入历史'
IFS= read -r -s -p '设置管理员密码（至少 12 个字符）：' password
printf '\n'
IFS= read -r -s -p '再次输入密码：' confirmation
printf '\n'
[[ ${#password} -ge 12 && ${#password} -le 256 && $password == "$confirmation" ]] || die '密码不一致或长度不在 12–256 字符之间'
docker pull "$TOONFLOW_IMAGE"
# 密码只经 stdin 传给无网络临时容器，不出现在命令行、日志或 .env 中。
password_hash=$(printf '%s' "$password" | docker run --rm -i --network none --entrypoint bun "$TOONFLOW_IMAGE" -e '
  const { randomBytes, scryptSync } = await import("node:crypto");
  const password = await Bun.stdin.text();
  if (password.length < 12 || password.length > 256) { console.error("密码长度须为 12–256，部分字符按两个计数"); process.exit(1); }
  const salt = randomBytes(32);
  console.log(salt.toString("hex") + ":" + scryptSync(password, salt, 64).toString("hex"));
')
unset password confirmation
[[ $password_hash =~ ^[a-f0-9]{64}:[a-f0-9]{128}$ ]] || die '生成密码摘要失败'
temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
sed '/^TOONFLOW_AUTH_ENABLED=/d; /^TOONFLOW_AUTH_USERNAME=/d; /^TOONFLOW_AUTH_PASSWORD_HASH=/d; /^TOONFLOW_PUBLIC_ORIGIN=/d' "$ENV_FILE" > "$temp"
printf 'TOONFLOW_AUTH_ENABLED=true\nTOONFLOW_PUBLIC_ORIGIN=%s\nTOONFLOW_AUTH_USERNAME=%s\nTOONFLOW_AUTH_PASSWORD_HASH=%s\n' "$origin" "$username" "$password_hash" >> "$temp"
chmod 600 "$temp"
mv -- "$temp" "$ENV_FILE"
printf '管理员登录已配置。首次安装运行 install.sh；已有实例更换镜像运行 update.sh，同版本改密码运行 install.sh。\n'
