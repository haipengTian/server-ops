#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=../lib.sh
source "$(dirname -- "$0")/../lib.sh"
require_root
lock_operation
load_env
export EGRESS_NETWORK_NAME="${COMPOSE_PROJECT_NAME}_backend"
require_commands docker python3 install mktemp cp chown
[[ $# == 0 ]] || die '不接收命令行节点链接，请在隐藏输入提示中粘贴'
[[ -t 0 ]] || die '请从交互终端运行，节点链接只在服务器本地输入'
[[ -n $(compose ps --status running -q cliproxyapi) ]] || die '请先启动 CLIProxyAPI'
docker network inspect "${COMPOSE_PROJECT_NAME}_backend" >/dev/null
dir="$CLIPROXY_DATA_DIR/secrets/egress"
[[ -d $CLIPROXY_DATA_DIR/secrets && ! -L $CLIPROXY_DATA_DIR/secrets && ! -L $dir ]] || die '数据目录缺失或代理目录是符号链接'
install -d -m 700 -o 10001 -g 10001 "$dir"
[[ ! -L $dir/config.json && ! -L $dir/config.previous.json ]] || die '代理配置不能是符号链接'
temp=$(mktemp "$dir/.config.XXXXXXXX")
trap 'rm -f -- "$temp"; unset node_link' EXIT
printf '请粘贴 VLESS Reality 链接（隐藏输入），回车确认：'
IFS= read -r -s node_link
printf '\n'
printf '%s' "$node_link" | python3 "$OPS_DIR/egress/vless_config.py" > "$temp"
unset node_link
chmod 600 "$temp"
chown 10001:10001 "$temp"
image=ghcr.io/sagernet/sing-box@sha256:80c639ba467885b28511fb7c980565c2d30a8752f778e7bc8abdbc91fbfd95ec
docker pull "$image"
# Suppress third-party validation output so malformed credentials cannot be echoed.
docker run --rm --network none --read-only --user 10001:10001 --cap-drop ALL \
  --security-opt no-new-privileges -v "$temp:/etc/sing-box/config.json:ro,Z" \
  "$image" check -c /etc/sing-box/config.json >/dev/null 2>&1 || die 'sing-box 配置校验失败，原配置保持不变'
[[ ! -f $dir/config.json ]] || cp -p -- "$dir/config.json" "$dir/config.previous.json"
mv -- "$temp" "$dir/config.json"
docker compose --env-file "$ENV_FILE" -f "$OPS_DIR/egress/compose.yml" \
  -p "${COMPOSE_PROJECT_NAME}-egress" up -d --force-recreate egress
printf '代理容器已启动，尚未修改应用出网配置。请执行 bash egress/status.sh 检查出口。\n'
