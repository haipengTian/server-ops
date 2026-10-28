#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
[[ -t 0 ]] || die '请在自己的交互终端运行，以隐藏密码输入'
read -r -p '管理员账号：' admin_name
read -r -s -p '管理员密码（至少 12 字节）：' admin_password
printf '\n'
read -r -s -p '再次输入密码：' admin_confirmation
printf '\n'
[[ $admin_password == "$admin_confirmation" ]] || die '两次密码不一致'
trap 'unset admin_password admin_confirmation' EXIT
printf '%s\n%s\n' "$admin_name" "$admin_password" | compose exec -T api /app/mail-admin
