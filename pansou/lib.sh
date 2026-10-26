#!/usr/bin/env bash
OPS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$OPS_DIR/.env"
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $(id -u) == 0 ]] || die '请用 sudo 或 root 执行'; }
require_commands() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done
}
lock_operation() {
  require_commands flock
  exec 9>"$OPS_DIR/.operation.lock"
  flock -n 9 || die '另一个 PanSou 部署操作正在进行'
}
load_env() {
  require_commands jq realpath
  [[ -f $ENV_FILE && ! -L $ENV_FILE ]] || die '先运行 bash pansou/init.sh；.env 不能是符号链接'
  local line key value required
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die '.env 格式须为 KEY=value'
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      PANSOU_IMAGE|PANSOU_DOMAIN|PANSOU_HOST_PORT|PANSOU_DATA_DIR|PANSOU_WAIT_SECONDS|COMPOSE_PROJECT_NAME|TZ|PANSOU_MEM_LIMIT|PANSOU_CPUS|ADMIN_USERS|AUTH_JWT_SECRET|CERTBOT_EMAIL|CHANNELS|ENABLED_PLUGINS) ;;
      *) die "不支持的配置键：$key" ;;
    esac
    [[ ! ${seen[$key]+set} ]] || die "配置键重复：$key"
    seen[$key]=1
    # 配置是字面数据，绝不能 source 成 root shell；同时避免 Compose 再插值。
    [[ $value != *[[:space:]\$\`\"\'\\\#]* ]] || die "配置 $key 不支持空白、引号、反斜杠、井号或变量展开"
    export "$key=$value"
  done < "$ENV_FILE"
  for required in PANSOU_IMAGE PANSOU_DOMAIN PANSOU_HOST_PORT PANSOU_DATA_DIR PANSOU_WAIT_SECONDS COMPOSE_PROJECT_NAME TZ PANSOU_MEM_LIMIT PANSOU_CPUS ADMIN_USERS AUTH_JWT_SECRET CHANNELS ENABLED_PLUGINS; do
    [[ ${seen[$required]+set} && -n ${!required} ]] || die "请填写 .env 中的 $required"
  done
  [[ $PANSOU_IMAGE =~ ^ghcr\.io/haipengtian/pansou-web(:sha-[a-f0-9]{7,40}|@sha256:[a-f0-9]{64})$ ]] || die '请使用个人镜像的固定 sha 标签或摘要'
  [[ $PANSOU_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die '域名无效'
  [[ $PANSOU_HOST_PORT =~ ^[0-9]{4,5}$ ]] || die '端口应在 1024-65535 之间'
  ((10#$PANSOU_HOST_PORT >= 1024 && 10#$PANSOU_HOST_PORT <= 65535)) || die '端口应在 1024-65535 之间'
  [[ $PANSOU_WAIT_SECONDS =~ ^[0-9]{2,4}$ ]] || die '等待时间至少 30 秒'
  ((10#$PANSOU_WAIT_SECONDS >= 30)) || die '等待时间至少 30 秒'
  [[ $COMPOSE_PROJECT_NAME =~ ^[a-z][a-z0-9_-]{2,40}$ ]] || die 'Compose 项目名无效'
  [[ $PANSOU_DATA_DIR =~ ^/([a-zA-Z0-9_-]+/)*[a-zA-Z0-9_-]+$ ]] || die '数据目录应为无空白、无 .. 的专用绝对路径'
  case "$PANSOU_DATA_DIR" in /opt|/var|/root|/home|/etc|/usr|/tmp|/var/lib) die '请使用专用数据子目录' ;; esac
  [[ $(realpath -m -- "$PANSOU_DATA_DIR") == "$PANSOU_DATA_DIR" ]] || die '数据目录不能经过符号链接'
  [[ $TZ =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die '时区格式无效'
  [[ $PANSOU_MEM_LIMIT =~ ^[1-9][0-9]*[mg]$ ]] || die '内存上限应使用正整数加 m 或 g'
  [[ $PANSOU_CPUS =~ ^[0-9]+(\.[0-9]+)?$ && $PANSOU_CPUS =~ [1-9] ]] || die 'CPU 上限应为正数'
  [[ $ADMIN_USERS =~ ^[A-Za-z0-9_.-]{3,32}:[A-Za-z0-9_.\!@%+=-]{16,72}$ ]] || die 'ADMIN_USERS 需为单个用户名:密码；请按 .env.example 的字符与长度要求填写'
  [[ $AUTH_JWT_SECRET =~ ^[a-f0-9]{64}$ ]] || die '请保留 init.sh 生成的 64 位十六进制 JWT 密钥'
  export CERTBOT_EMAIL=${CERTBOT_EMAIL:-}
}
compose() { docker compose --project-directory "$OPS_DIR" --env-file "$ENV_FILE" -f "$OPS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT_NAME" "$@"; }
check_docker() {
  require_commands docker curl
  docker info >/dev/null 2>&1 || die 'Docker 未启动或当前用户无权访问'
  docker compose version >/dev/null || die '需要 Docker Compose 插件'
  compose config --quiet
}
check_seed_env() {
  jq -e --arg channels "$CHANNELS" --arg plugins "$ENABLED_PLUGINS" '
    (.default_channels|sort)==($channels|split(",")|sort) and
    (.enabled_plugins|sort)==($plugins|split(",")|sort)
  ' "$OPS_DIR/defaults.json" >/dev/null || die '首次安装必须保留 init.sh 生成的完整频道和插件清单'
}
check_settings() {
  local settings="$PANSOU_DATA_DIR/app/admin/settings.json"
  [[ -f $settings ]] || die '找不到实际持久化的 settings.json'
  jq -e '(.enabled_plugins|type)=="array" and (.default_channels|type)=="array"' "$settings" >/dev/null || die '持久化配置无效'
  if [[ ${1:-} == --initial ]]; then
    jq -e --slurpfile defaults "$OPS_DIR/defaults.json" '
      (.enabled_plugins|sort)==($defaults[0].enabled_plugins|sort) and
      (.default_channels|sort)==($defaults[0].default_channels|sort) and
      ((.allowed_channels // [])|length)==0 and ((.allowed_cloud_types // [])|length)==0
    ' "$settings" >/dev/null || die '实际配置不是完整初始清单，已保留原文件；请检查是否用了旧数据目录'
  fi
  jq -r '"持久化设置：\(.default_channels|length) 个默认频道，\(.enabled_plugins|length) 个已配置启用插件。"' "$settings"
}
verify_http() {
  local base="http://127.0.0.1:$PANSOU_HOST_PORT" code path
  curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 "$base/api/health" >/dev/null || return 1
  curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 "$base/" >/dev/null || return 1
  curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 "$base/admin" >/dev/null || return 1
  for path in /api/admin/settings /api/search/options; do
    code=$(curl --noproxy '*' --silent --show-error --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "$base$path") || return 1
    [[ $code == 401 ]] || { printf '匿名访问 %s 未被拒绝（HTTP %s）\n' "$path" "$code" >&2; return 1; }
  done
}
