#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
[[ $# == 1 ]] || die '用法：bash setup-web.sh 证书联系邮箱'
curl -fsS "http://127.0.0.1:$MAIL_CENTER_PORT/api/v1/auth/status" | grep -q '"initialized":true' || die '请先运行 bootstrap-admin.sh 创建管理员'
bash "$(nginx_tool)" --domain "$MAIL_DOMAIN" --upstream "http://127.0.0.1:$MAIL_CENTER_PORT" --email "$1"
printf '请访问 https://%s 登录并测试真实邮箱。\n' "$MAIL_DOMAIN"
