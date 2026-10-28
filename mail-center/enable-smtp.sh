#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
[[ $# == 1 ]] || die '用法：bash enable-smtp.sh 证书联系邮箱'
curl -fsS "http://127.0.0.1:$MAIL_CENTER_PORT/api/v1/auth/status" | grep -q '"initialized":true' || die '请先创建管理员并验证网页'
compose --profile smtp pull smtp
bash "$(nginx_tool)" --domain "$MX_HOSTNAME" --upstream "http://127.0.0.1:$MAIL_CENTER_PORT" --email "$1"
bash "$OPS_DIR/sync-smtp-certificate.sh"
hook=/etc/letsencrypt/renewal-hooks/deploy/mail-center-smtp
[[ ! -e $hook ]] || grep -Fq '# Managed by server-ops/mail-center' "$hook" || die '已有同名续期 hook，保留原文件'
{
  printf '#!/usr/bin/env bash\n# Managed by server-ops/mail-center\nset -euo pipefail\n'
  printf 'exec bash %q\n' "$OPS_DIR/sync-smtp-certificate.sh"
} > "$hook"
chmod 700 "$hook"
compose --profile smtp up -d --no-build --pull never --wait --wait-timeout 120 smtp
printf 'Postfix 已启动。还需放行服务器防火墙、云安全组及供应商的入站 TCP 25，并从外网验证。\n'
printf '验证通过后将 %s 的 MX 改为 %s，优先级 10。\n' "$RECEIVE_DOMAIN" "$MX_HOSTNAME"
