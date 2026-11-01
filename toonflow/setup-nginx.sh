#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 ]] || die '用法：bash setup-nginx.sh <HTTPS证书邮箱>'
email=$1
lock_operation
load_env
require_auth
require_commands curl python3
base="http://127.0.0.1:$TOONFLOW_HOST_PORT"
domain=${TOONFLOW_PUBLIC_ORIGIN#https://}
session=$(curl --noproxy '*' --fail --silent --show-error --max-time 10 -H "Host: $domain" "$base/api/auth/session")
if ! printf '%s' "$session" | python3 -c 'import json,sys; v=json.load(sys.stdin); sys.exit(0 if v.get("code")==200 and v.get("data",{}).get("enabled") is True and v["data"].get("authenticated") is False else 1)'; then
  die '当前服务未启用登录鉴权，拒绝配置公网入口'
fi
for path in /api/workspaces/list /api/settings/get /api/workspaces/files/read; do
  code=$(curl --noproxy '*' --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' -H "Host: $domain" "$base$path")
  [[ $code == 401 ]] || die "匿名接口 $path 未被拒绝（HTTP $code），拒绝开放公网"
done
bash "$OPS_DIR/../nginx/add-site.sh" --domain "$domain" --upstream "$base" --email "$email"
code=$(curl --noproxy '*' --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' "$TOONFLOW_PUBLIC_ORIGIN/api/workspaces/list")
[[ $code == 401 ]] || die "公网匿名接口检查失败（HTTP $code），请检查 DNS 与 nginx"
curl --noproxy '*' --fail --silent --show-error --max-time 15 "$TOONFLOW_PUBLIC_ORIGIN/login" | grep -q '/api/auth/login' || die '公网登录页检查失败'
printf '公网登录入口已就绪：%s\n' "$TOONFLOW_PUBLIC_ORIGIN"
