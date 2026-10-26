#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/server-ops-pansou-tests-XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${SIM:-}/output ]] || cat "$SIM/output" >&2; exit 1; }
[[ -f $ROOT/init.sh ]] || fail '缺少 PanSou 初始化入口，无法生成完整搜索来源'
mkdir "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 0
MOCK
cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/usr/bin/env bash
[[ $MODE != occupied ]] || echo 'LISTEN 0 128 127.0.0.1:9000 0.0.0.0:*'
exit 0
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
[[ " $* " == *' --noproxy * '* ]] || exit 92
case "${*: -1}" in
  */api/admin/settings|*/api/search/options) [[ $MODE == auth-open ]] && echo 200 || echo 401 ;;
  *) [[ $MODE != bad-http ]] ;;
esac
MOCK
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$SIM/events"
[[ $1 == info ]] && exit 0
if [[ $1 == inspect ]]; then
  case "$MODE" in
    stopped-owned) printf '%s|%s|%s\n' "$SIM/ops" "$SIM/ops/docker-compose.yml" "$PANSOU_DATA_DIR/app" ;;
    stopped-other-data) printf '%s|%s|/old/pansou/data\n' "$SIM/ops" "$SIM/ops/docker-compose.yml" ;;
    *) echo '/old/deploy|/old/deploy/docker-compose.yml|/old/data' ;;
  esac
  exit 0
fi
[[ $1 == compose ]] || exit 90
[[ ${2:-} == version ]] && exit 0
while [[ $1 != -p ]]; do shift; done
shift 2
case "$1" in
  version|config|pull) exit 0 ;;
  ps)
    if [[ $MODE == running || $2 == -a && $MODE == stopped-* ]]; then echo existing-container; fi
    exit 0 ;;
  up)
    [[ $MODE != unhealthy ]] || exit 1
    mkdir -p "$PANSOU_DATA_DIR/app/admin"
    if [[ ! -f $PANSOU_DATA_DIR/app/admin/settings.json ]]; then
      jq '. + {allowed_channels:[],allowed_cloud_types:[]}' "$SIM/ops/defaults.json" > "$PANSOU_DATA_DIR/app/admin/settings.json"
      if [[ $MODE == reduced ]]; then
        jq '.default_channels=["tgsearchers7"]' "$PANSOU_DATA_DIR/app/admin/settings.json" > "$SIM/reduced.json"
        mv "$SIM/reduced.json" "$PANSOU_DATA_DIR/app/admin/settings.json"
      fi
    fi ;;
  stop) touch "$SIM/stopped" ;;
  start) touch "$SIM/resumed" ;;
  *) exit 91 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
new_case() {
  export MODE=$1 SIM="$TEST_ROOT/$1"
  mkdir -p "$SIM/ops"
  cp "$ROOT/"*.sh "$ROOT/"*.yml "$ROOT/"*.json "$ROOT/.env.example" "$SIM/ops/"
  bash "$SIM/ops/init.sh" > "$SIM/output" 2>&1 || fail '初始化失败'
  sed -i "s|^PANSOU_DATA_DIR=.*|PANSOU_DATA_DIR=$SIM/data|; s|^ADMIN_USERS=.*|ADMIN_USERS=fixture:synthetic-password-123|" "$SIM/ops/.env"
}
expect_failure() {
  if bash "$SIM/ops/$1" >> "$SIM/output" 2>&1; then fail "$MODE 不应成功"; fi
}
new_case init
jq -e '(.enabled_plugins|length)==74 and (.default_channels|length)==111 and (.enabled_plugins|unique|length)==74 and (.default_channels|unique|length)==111 and (.enabled_plugins|index("qiwei"))!=null and (.enabled_plugins|index("xdpan"))!=null' "$ROOT/defaults.json" >/dev/null || fail '完整清单不正确'
cp "$SIM/ops/.env" "$SIM/before"
bash "$SIM/ops/init.sh" >> "$SIM/output" 2>&1
cmp "$SIM/before" "$SIM/ops/.env" || fail '重复初始化改写原密钥或配置'
[[ $(stat -c %a "$SIM/ops/.env") == 600 ]] || fail '配置权限不是 600'
if grep -Eq 'synthetic-password|AUTH_JWT_SECRET=' "$SIM/output"; then fail '输出泄露凭据'; fi
printf 'PASS 初始化完整来源、限制配置权限、重跑保留配置\n'

new_case install
bash "$SIM/ops/install.sh" >> "$SIM/output" 2>&1 || fail '全新安装失败'
[[ ! -f $SIM/stopped ]] || fail '成功安装却停止了服务'
grep -q 'up -d --wait --wait-timeout' "$SIM/events" || fail '未等待健康检查'
jq -e '(.default_channels|length)==111 and (.enabled_plugins|length)==74' "$SIM/data/app/admin/settings.json" >/dev/null || fail '未验证实际持久化配置'
# 后台调整后，普通验证不强行恢复全开。
jq '.enabled_plugins=["pansearch"] | .default_channels=["tgsearchers7"]' "$SIM/data/app/admin/settings.json" > "$SIM/new.json"
mv "$SIM/new.json" "$SIM/data/app/admin/settings.json"
bash "$SIM/ops/verify.sh" >> "$SIM/output" 2>&1 || fail '普通检查错误拒绝了后台调整'
jq -e '.enabled_plugins==["pansearch"]' "$SIM/data/app/admin/settings.json" >/dev/null || fail '覆盖了后台修改'
printf 'PASS 安装等待健康、验证落盘、保留后台调整\n'

for mode in unhealthy reduced auth-open bad-http; do
  new_case "$mode"
  expect_failure install.sh
  [[ -f $SIM/stopped ]] || fail "$mode 失败后未停止本次容器"
done
printf 'PASS 健康失败、落盘缺频道、认证失效、网页失败均阻止上线\n'

for mode in running occupied; do
  new_case "$mode"
  expect_failure install.sh
  [[ ! -f $SIM/stopped ]] || fail "$mode 错误停止了原服务"
  ! grep -Eq 'up -d|pull pansou' "$SIM/events" || fail "$mode 仍执行了部署"
done
new_case existing-settings
mkdir -p "$SIM/data/app/admin"
echo '{"enabled_plugins":["pansearch"],"default_channels":["tgsearchers7"]}' > "$SIM/data/app/admin/settings.json"
cp "$SIM/data/app/admin/settings.json" "$SIM/settings-before"
expect_failure install.sh
cmp "$SIM/settings-before" "$SIM/data/app/admin/settings.json" || fail '覆盖旧数据'
[[ ! -f $SIM/stopped ]] || fail '修改配置检查失败却停止服务'
printf 'PASS 原容器、端口冲突及旧配置均提前阻止安装\n'

new_case injected-env
# shellcheck disable=SC2016
printf '\nUNSUPPORTED=$(touch %s/pwned)\n' "$SIM" >> "$SIM/ops/.env"
expect_failure install.sh
[[ ! -f $SIM/pwned ]] || fail '将 .env 作为 shell 执行'
new_case reduced-env
sed -i 's/^CHANNELS=.*/CHANNELS=tgsearchers7/' "$SIM/ops/.env"
expect_failure install.sh
[[ ! -f $SIM/events ]] || fail '缩减来源未在调用 Docker 前拒绝'
new_case missing-admin
sed -i 's/^ADMIN_USERS=.*/ADMIN_USERS=/' "$SIM/ops/.env"
expect_failure install.sh
[[ ! -f $SIM/events ]] || fail '缺少管理员仍调用 Docker'
printf 'PASS 不执行环境文件、拒绝缩减初始清单和空管理员\n'

new_case existing-users
mkdir -p "$SIM/data/app/admin"
echo '{"users":[{"username":"old-user"}]}' > "$SIM/data/app/admin/users.json"
expect_failure install.sh
[[ ! -f $SIM/stopped ]] || fail '发现旧账号数据后停止了服务'
printf 'PASS 全新安装拒绝混入已有账号\n'

for mode in stopped-foreign stopped-other-data; do
  new_case "$mode"
  expect_failure install.sh
  ! grep -Eq 'up -d|pull pansou|stop pansou' "$SIM/events" || fail '安装替换了既有停止实例'
done
new_case stopped-owned
bash "$SIM/ops/install.sh" >> "$SIM/output" 2>&1 || fail '不能重试本部署的失败安装'
printf 'PASS 拒绝同名项目的其他停止实例，允许本部署原数据目录重试\n'

new_case backup
export MODE=running
mkdir -p "$SIM/data/app/admin"
echo '{"enabled_plugins":["pansearch"]}' > "$SIM/data/app/admin/settings.json"
bash "$SIM/ops/backup.sh" >> "$SIM/output" 2>&1 || fail '备份失败'
[[ -f $SIM/stopped && -f $SIM/resumed ]] || fail '备份未暂停并恢复运行中的服务'
archive=$(find "$SIM/data/backups" -name data.tar.gz -print -quit)
[[ -n $archive ]] || fail '缺少备份数据'
tar -xOf "$archive" ./admin/settings.json | grep -q pansearch || fail '备份缺少后台配置'
[[ -f ${archive%/*}/deployment.env ]] || fail '备份缺少认证密钥配置'
[[ $(stat -c %a "${archive%/*}") == 700 ]] || fail '备份目录权限错误'
printf 'PASS 一致性备份包含设置和密钥，并恢复服务\n'
