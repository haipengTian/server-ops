#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
compose config --quiet
compose pull postgres api web gateway
compose up -d --no-build --pull never --wait --wait-timeout 180 postgres api web gateway
printf '网页服务已启动在 127.0.0.1:%s，尚未接入公网域名。\n' "$MAIL_CENTER_PORT"
printf '首次安装：运行 bash bootstrap-admin.sh，由你创建管理员，再运行 bash setup-web.sh 证书联系邮箱。\n'
printf '本命令只处理网页服务。SMTP 的首次启用或镜像更新请运行 enable-smtp.sh；收信验收前保持现有 MX。\n'
