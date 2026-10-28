#!/usr/bin/env bash
set -euo pipefail
umask 077
OPS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${MAIL_CENTER_ENV_FILE:-$OPS_DIR/.env}
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $(id -u) == 0 ]] || die '请使用 root 或 sudo bash 执行'; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
validate_image() {
  local path='ghcr\.io/[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_./-]*'
  [[ $1 =~ ^${path}:(v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9_.-]+)?|sha-[a-f0-9]{12,40})$ || $1 =~ ^${path}@sha256:[a-f0-9]{64}$ ]] ||
    die "${2:-镜像} 必须是 GHCR 固定版本 vX.Y.Z、sha-提交号或镜像摘要；不接受 latest/main"
}
lock_operation() {
  exec 9>"$OPS_DIR/.operation.lock"
  flock -n 9 || die '另一个 Mail Center 操作正在进行'
}
load_env() {
  [[ -f $ENV_FILE ]] || die '请先运行 init.sh'
  local key value
  while IFS='=' read -r key value || [[ -n $key ]]; do
    value=${value%$'\r'}
    case "$key" in
      MAIL_CENTER_PROJECT|MAIL_CENTER_VERSION|MAIL_CENTER_API_IMAGE|MAIL_CENTER_WEB_IMAGE|MAIL_CENTER_SMTP_IMAGE|MAIL_DOMAIN|RECEIVE_DOMAIN|MX_HOSTNAME|MAIL_CENTER_PORT|POSTGRES_PASSWORD|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|MAIL_CENTER_BACKEND_SOURCE|MAIL_CENTER_FRONTEND_SOURCE|MAIL_CENTER_SMTP_BIND|MAIL_CENTER_SMTP_PORT)
        export "$key=$value" ;;
      ''|'#'*) ;;
      *) die "未知配置项：$key（使用 KEY=value，不使用 export 或引号）" ;;
    esac
  done < "$ENV_FILE"
  valid_domain "${MAIL_DOMAIN:-}" && valid_domain "${RECEIVE_DOMAIN:-}" && valid_domain "${MX_HOSTNAME:-}" || die '域名配置不正确'
  [[ ${POSTGRES_PASSWORD:-} =~ ^[a-f0-9]{64}$ ]] || die '数据库密码必须为 init.sh 生成的 64 位十六进制值'
  [[ ${MAIL_CENTER_PORT:-} =~ ^[0-9]{4,5}$ ]] && ((10#$MAIL_CENTER_PORT >= 1024 && 10#$MAIL_CENTER_PORT <= 65535)) || die '网页回环端口需在 1024—65535'
  [[ ${MAIL_CENTER_PROJECT:-} =~ ^[a-z][a-z0-9-]{1,50}$ ]] || die 'Compose 项目名称不正确'
  validate_image "${MAIL_CENTER_API_IMAGE:-}" MAIL_CENTER_API_IMAGE
  validate_image "${MAIL_CENTER_WEB_IMAGE:-}" MAIL_CENTER_WEB_IMAGE
  validate_image "${MAIL_CENTER_SMTP_IMAGE:-}" MAIL_CENTER_SMTP_IMAGE
}
compose() { docker compose --project-directory "$OPS_DIR" --env-file "$ENV_FILE" -f "$OPS_DIR/compose.yaml" "$@"; }
check_docker() { docker compose version >/dev/null && docker info >/dev/null || die 'Docker / Compose 不可用'; }
nginx_tool() {
  if [[ -f $OPS_DIR/tools/nginx/add-site.sh ]]; then
    printf '%s\n' "$OPS_DIR/tools/nginx/add-site.sh"
  else
    printf '%s\n' "$OPS_DIR/../nginx/add-site.sh"
  fi
}
