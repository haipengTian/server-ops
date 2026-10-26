#!/usr/bin/env bash
# 仅在隔离的 Linux CI 上运行；使用合成账号和独立数据目录，不接受生产配置。
set -euo pipefail
[[ ${CI:-} == true ]] || { echo '此测试仅允许在 CI 隔离环境运行' >&2; exit 1; }
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/server-ops-pansou-image-XXXXXXXX)
mkdir "$TEST_ROOT/ops"
cp "$ROOT/"*.sh "$ROOT/"*.yml "$ROOT/"*.json "$ROOT/.env.example" "$TEST_ROOT/ops/"
cd "$TEST_ROOT/ops"
cleanup() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then docker compose logs --tail=100 pansou; fi
  docker compose down --timeout 30 || true
  rm -rf -- "$TEST_ROOT"
  exit "$status"
}
trap cleanup EXIT
bash init.sh
sed -i "s|^PANSOU_DATA_DIR=.*|PANSOU_DATA_DIR=$TEST_ROOT/data|; s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=pansou-ci|; s|^ADMIN_USERS=.*|ADMIN_USERS=fixture:synthetic-password-123|" .env
bash install.sh
bash verify.sh --initial
[[ $(docker compose port pansou 80) == 127.0.0.1:9000 ]]
base=http://127.0.0.1:9000
curl --noproxy '*' --fail --silent --show-error -H 'Content-Type: application/json' \
  --data '{"username":"fixture","password":"synthetic-password-123"}' "$base/api/auth/login" > "$TEST_ROOT/login.json"
jq -e '.role=="admin" and (.token|length)>0' "$TEST_ROOT/login.json" >/dev/null
# 测试凭据/令牌只存在临时文件里，不打印，也不上传为 CI artifact。
jq -r '"Authorization: Bearer " + .token' "$TEST_ROOT/login.json" > "$TEST_ROOT/auth.header"
curl --noproxy '*' --fail --silent --show-error -H "@$TEST_ROOT/auth.header" "$base/api/admin/plugins" > "$TEST_ROOT/plugins.json"
jq -e --slurpfile defaults defaults.json '
  (.data.plugins|map(.name)|sort)==($defaults[0].enabled_plugins|sort) and
  ([.data.plugins[]|select(.enabled==false)]|length)==0
' "$TEST_ROOT/plugins.json" >/dev/null
curl --noproxy '*' --fail --silent --show-error -H "@$TEST_ROOT/auth.header" "$base/api/search/options" > "$TEST_ROOT/options.json"
jq -e --slurpfile defaults defaults.json '
  (.data.channels|sort)==($defaults[0].default_channels|sort) and
  (.data.plugins|sort)==($defaults[0].enabled_plugins|sort) and (.data.cloud_types|length)>0
' "$TEST_ROOT/options.json" >/dev/null
echo 'PASS 真实镜像管理员登录、完整插件注册/启用、111 个可选频道与网盘类型'

# 通过实际 API 修改，重建容器后核对数据仍在；绝不将全开清单再次覆盖后台。
curl --noproxy '*' --fail --silent --show-error -X PUT -H "@$TEST_ROOT/auth.header" -H 'Content-Type: application/json' \
  --data '{"enabled_plugins":["pansearch"],"default_channels":["tgsearchers7"],"allowed_channels":[],"allowed_cloud_types":[]}' \
  "$base/api/admin/settings" > "$TEST_ROOT/saved.json"
jq -e '.data.settings.enabled_plugins==["pansearch"]' "$TEST_ROOT/saved.json" >/dev/null
bash backup.sh
backup=$(find "$TEST_ROOT/data/backups" -name COMPLETE -print -quit)
[[ -n $backup ]]
tar -xOf "${backup%/*}/data.tar.gz" ./admin/settings.json | jq -e '.enabled_plugins==["pansearch"]' >/dev/null
docker compose up -d --force-recreate --wait --wait-timeout 180
bash verify.sh
curl --noproxy '*' --fail --silent --show-error -H "@$TEST_ROOT/auth.header" "$base/api/admin/settings" |
  jq -e '.data.settings.enabled_plugins==["pansearch"] and .data.settings.default_channels==["tgsearchers7"]' >/dev/null
echo 'PASS 真实后台配置变更、一致性备份、重建容器后保留设置'
