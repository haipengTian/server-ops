#!/usr/bin/env bash
# 公共入口的校验和站点渲染；不读取应用密码或执行用户配置。
# 这些路径由 source 本文件的入口使用。
# shellcheck disable=SC2034
OPS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034
CONF_DIR=/etc/nginx/conf.d
# shellcheck disable=SC2034
MAP_CONF=/etc/nginx/conf.d/00-server-ops-websocket-map.conf
# shellcheck disable=SC2034
WEBROOT=/var/www/certbot
# shellcheck disable=SC2034
CERT_DIR=/etc/letsencrypt/live
# shellcheck disable=SC2034
RELOAD_HOOK=/etc/letsencrypt/renewal-hooks/deploy/server-ops-nginx-reload
MARKER='# Managed by server-ops/nginx'

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $(id -u) == 0 ]] || die '请使用 sudo bash 或 root 执行'; }
require_commands() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null || die "缺少命令 $cmd，请先运行 nginx/install.sh"; done
}
lock_operation() {
  mkdir -p /run/lock
  exec 9>/run/lock/server-ops-nginx.lock
  flock -n 9 || die '另一个 nginx 安装或站点操作正在进行'
}
valid_domain() {
  [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}
require_owned() {
  local file=$1
  [[ ! -L $file ]] || die "拒绝覆盖符号链接：$file"
  [[ ! -e $file || -f $file ]] || die "目标不是普通文件：$file"
  [[ ! -f $file ]] || grep -Fxq -- "$MARKER" "$file" || die "已有文件不由公共 nginx 脚本管理，保留原文件：$file"
}
render() {
  local template=$1
  local -a auth_args=()
  if [[ -n ${BASIC_AUTH_FILE:-} ]]; then
    auth_args=(-e "s|__BASIC_AUTH_FILE__|$BASIC_AUTH_FILE|g")
  else
    auth_args=(-e '/# BEGIN BASIC AUTH/,/# END BASIC AUTH/d')
  fi
  sed -e "s|__DOMAIN__|$DOMAIN|g" \
      -e "s|__UPSTREAM__|$UPSTREAM|g" \
      -e "s|__SSL_NAME__|$SSL_NAME|g" \
      -e "s|__SSL_VERIFY__|$SSL_VERIFY|g" \
      -e "s|__UPSTREAM_CA__|$UPSTREAM_CA|g" \
      "${auth_args[@]}" \
      "$OPS_DIR/templates/$template"
}
http_status_ok() { [[ $1 =~ ^[234][0-9][0-9]$ ]]; }
probe_upstream() {
  local url="$UPSTREAM/" code
  local -a args=(--silent --show-error --noproxy '*' --connect-timeout 3 --max-time 10 --output /dev/null --write-out '%{http_code}')
  if [[ $UPSTREAM_SCHEME == https ]]; then
    if [[ $UPSTREAM_INSECURE == true ]]; then
      args+=(--insecure)
    else
      args+=(--cacert "$UPSTREAM_CA")
    fi
    if [[ -n $UPSTREAM_SERVER_NAME ]]; then
      args+=(--resolve "$UPSTREAM_SERVER_NAME:$UPSTREAM_PORT:$UPSTREAM_HOST")
      url="https://$UPSTREAM_SERVER_NAME:$UPSTREAM_PORT/"
    fi
  fi
  code=$(curl "${args[@]}" "$url") || die "无法连接后端 $UPSTREAM：请核对端口、HTTP/HTTPS 协议及证书；未修改站点"
  http_status_ok "$code" || die "后端返回 HTTP $code，请先修复应用；未修改站点"
}
apply_nginx() {
  local diagnostics
  if ! diagnostics=$(nginx -t 2>&1); then
    printf '%s\n' "$diagnostics" >&2
    return 1
  fi
  printf '%s\n' "$diagnostics" >&2
  # nginx 遇到同域名冲突通常仍返回 0，甚至可能继续服务旧后端。
  if [[ -n ${DOMAIN:-} ]] && grep -Fq "conflicting server name \"$DOMAIN\"" <<< "$diagnostics"; then
    printf '当前域名在其他监听配置中冲突，停止发布：%s\n' "$DOMAIN" >&2
    return 1
  fi
  systemctl reload nginx
}
wait_https() {
  local attempt code
  for attempt in {1..10}; do
    # 验证真实证书和域名；404/401 是受保护面板常见的正常根路径响应。
    if code=$(curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
      --resolve "$DOMAIN:443:127.0.0.1" --output /dev/null --write-out '%{http_code}' \
      "https://$DOMAIN/" 2> "$TRANSACTION/https-error") && http_status_ok "$code" &&
      { [[ -z ${BASIC_AUTH_FILE:-} ]] || [[ $code == 401 ]]; }; then
      return 0
    fi
    [[ $attempt == 10 ]] || sleep 1
  done
  cat "$TRANSACTION/https-error" >&2
  [[ -z ${BASIC_AUTH_FILE:-} ]] || die "Basic Auth 就绪检查失败（最后匿名 HTTP ${code:-000}，预期 401），请检查密码文件权限及 nginx 错误日志"
  die "HTTPS 就绪检查失败（最后 HTTP ${code:-000}），请检查证书、站点和 nginx 错误日志"
}
