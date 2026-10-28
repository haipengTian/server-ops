#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
[[ $# == 3 || $# == 6 ]] || die '用法：bash init.sh 网页域名 收信域名 MX主机名 [后端镜像 前端镜像 SMTP镜像]'
valid_domain "$1" && valid_domain "$2" && valid_domain "$3" || die '域名格式不正确'
api_image=${4:-ghcr.io/haipengtian/mail-center:v0.1.0}
web_image=${5:-ghcr.io/haipengtian/mail-center-ui:v0.1.0}
smtp_image=${6:-ghcr.io/haipengtian/mail-center-smtp:v0.1.0}
validate_image "$api_image" MAIL_CENTER_API_IMAGE
validate_image "$web_image" MAIL_CENTER_WEB_IMAGE
validate_image "$smtp_image" MAIL_CENTER_SMTP_IMAGE
[[ ! -e $ENV_FILE ]] || die '.env 已存在，保留原文件；请直接安装或编辑原配置'
[[ ! -e $OPS_DIR/data ]] || die '已有数据目录但没有配置，请恢复原 .env 或备份，不生成新密码'
command -v openssl >/dev/null || die '需要 openssl 生成数据库密码'
db_password=$(openssl rand -hex 32)
cat > "$ENV_FILE" <<EOF
MAIL_CENTER_PROJECT=mail-center
MAIL_CENTER_API_IMAGE=$api_image
MAIL_CENTER_WEB_IMAGE=$web_image
MAIL_CENTER_SMTP_IMAGE=$smtp_image
MAIL_DOMAIN=$1
RECEIVE_DOMAIN=$2
MX_HOSTNAME=$3
MAIL_CENTER_PORT=3013
POSTGRES_PASSWORD=$db_password
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
EOF
chmod 600 "$ENV_FILE"
install -d -m 700 "$OPS_DIR/data" "$OPS_DIR/backups"
install -d -m 700 -o 10001 -g 10001 "$OPS_DIR/data/mail"
install -d -m 700 "$OPS_DIR/data/postgres" "$OPS_DIR/data/smtp-queue" "$OPS_DIR/data/smtp-tls"
printf '配置已生成。确认三个镜像已由 Actions 发布成功后，运行 bash install.sh；密码仅保存在本机 .env。\n'
