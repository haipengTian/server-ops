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
  flock -n 9 || die '另一个 Toonflow 部署操作正在进行'
}
validate_image() {
  [[ $1 =~ ^ghcr\.io/haipengtian/toonflow:([0-9]+\.[0-9]+\.[0-9]+-custom\.[0-9]+)$ || $1 =~ ^ghcr\.io/haipengtian/toonflow@sha256:[a-f0-9]{64}$ ]] || die '请使用 ghcr.io/haipengtian/toonflow 的固定 custom 版本或摘要'
}
load_env() {
  [[ -f $ENV_FILE && ! -L $ENV_FILE ]] || die '先运行 init.sh；.env 不能是符号链接'
  local line key value required
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die '.env 格式须为 KEY=value'
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      TOONFLOW_IMAGE|TOONFLOW_HOST_PORT|TOONFLOW_DATA_DIR|TOONFLOW_WAIT_SECONDS|COMPOSE_PROJECT_NAME|TOONFLOW_MEM_LIMIT|TOONFLOW_CPUS|TZ|TOONFLOW_AUTH_ENABLED|TOONFLOW_PUBLIC_ORIGIN|TOONFLOW_AUTH_USERNAME|TOONFLOW_AUTH_PASSWORD_HASH) ;;
      *) die "不支持的配置键：$key" ;;
    esac
    [[ ! ${seen[$key]+set} ]] || die "配置键重复：$key"
    seen[$key]=1
    # .env 作为字面数据读取，不以 root 身份执行其中内容。
    [[ $value != *[[:space:]\$\`\"\'\\\#]* ]] || die "配置 $key 不能包含空白、引号或变量展开"
    export "$key=$value"
  done < "$ENV_FILE"
  for required in TOONFLOW_IMAGE TOONFLOW_HOST_PORT TOONFLOW_DATA_DIR TOONFLOW_WAIT_SECONDS COMPOSE_PROJECT_NAME TOONFLOW_MEM_LIMIT TOONFLOW_CPUS TZ; do
    [[ ${seen[$required]+set} && -n ${!required} ]] || die "请填写 .env 中的 $required"
  done
  validate_image "$TOONFLOW_IMAGE"
  [[ $TOONFLOW_HOST_PORT =~ ^[0-9]{4,5}$ ]] || die '端口须在 1024-65535 之间'
  ((10#$TOONFLOW_HOST_PORT >= 1024 && 10#$TOONFLOW_HOST_PORT <= 65535)) || die '端口须在 1024-65535 之间'
  [[ $TOONFLOW_WAIT_SECONDS =~ ^[0-9]{2,4}$ ]] || die '等待时间至少 30 秒'
  ((10#$TOONFLOW_WAIT_SECONDS >= 30)) || die '等待时间至少 30 秒'
  [[ $COMPOSE_PROJECT_NAME =~ ^[a-z][a-z0-9_-]{2,40}$ ]] || die 'Compose 项目名无效'
  [[ $TOONFLOW_DATA_DIR =~ ^/([a-zA-Z0-9_-]+/)+[a-zA-Z0-9_-]+$ ]] || die '数据目录须为专用绝对路径，不含空白或 ..'
  case "$TOONFLOW_DATA_DIR" in /var/lib|/usr/local|/opt/server-ops) die '请使用 Toonflow 专用数据子目录' ;; esac
  require_commands realpath
  [[ $(realpath -m -- "$TOONFLOW_DATA_DIR") == "$TOONFLOW_DATA_DIR" && ! -L $TOONFLOW_DATA_DIR/app ]] || die '数据目录不能经过符号链接'
  [[ $TOONFLOW_MEM_LIMIT =~ ^[1-9][0-9]*[mg]$ ]] || die '内存上限应使用正整数加 m 或 g'
  [[ $TOONFLOW_CPUS =~ ^[0-9]+(\.[0-9]+)?$ && $TOONFLOW_CPUS =~ [1-9] ]] || die 'CPU 上限须为正数'
  [[ $TZ =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die '时区格式无效'
}
require_auth() {
  [[ ${TOONFLOW_AUTH_ENABLED:-} == true ]] || die '必须先运行 setup-auth.sh 开启登录鉴权'
  [[ ${TOONFLOW_PUBLIC_ORIGIN:-} =~ ^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die '公网来源须为 https://域名，不含路径或端口'
  [[ ${TOONFLOW_AUTH_USERNAME:-} =~ ^[a-zA-Z0-9@._-]{1,64}$ ]] || die '请设置管理员用户名'
  [[ ${TOONFLOW_AUTH_PASSWORD_HASH:-} =~ ^[a-f0-9]{64}:[a-f0-9]{128}$ ]] || die '必须先运行 setup-auth.sh 设置管理员密码'
}
compose() { docker compose --project-directory "$OPS_DIR" --env-file "$ENV_FILE" -f "$OPS_DIR/docker-compose.yml" "$@"; }
check_docker() {
  require_commands docker
  docker info >/dev/null 2>&1 || die 'Docker 未启动或当前用户无权访问'
  docker compose version >/dev/null || die '需要 Docker Compose 插件'
  compose config --quiet
}
set_image() {
  local temp
  temp=$(mktemp "$OPS_DIR/.env.XXXXXX")
  if ! sed "s|^TOONFLOW_IMAGE=.*|TOONFLOW_IMAGE=$1|" "$ENV_FILE" > "$temp"; then
    rm -f -- "$temp"; return 1
  fi
  chmod 600 "$temp"
  mv -- "$temp" "$ENV_FILE"
  export TOONFLOW_IMAGE=$1
}
start_app() { compose up -d --wait --wait-timeout "$TOONFLOW_WAIT_SECONDS" toonflow; }
resume_app() { compose up -d --no-recreate --no-deps --pull never --wait --wait-timeout "$TOONFLOW_WAIT_SECONDS" toonflow; }
create_backup() {
  require_commands tar
  [[ -d $TOONFLOW_DATA_DIR/app ]] || die '找不到应用数据目录'
  mkdir -p "$TOONFLOW_DATA_DIR/backups" "$TOONFLOW_DATA_DIR/state"
  chmod 700 "$TOONFLOW_DATA_DIR/backups" "$TOONFLOW_DATA_DIR/state"
  BACKUP_PATH=$(mktemp -d "$TOONFLOW_DATA_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  tar -czf "$BACKUP_PATH/data.tar.gz" -C "$TOONFLOW_DATA_DIR/app" .
  tar -tzf "$BACKUP_PATH/data.tar.gz" >/dev/null
  cp "$ENV_FILE" "$BACKUP_PATH/deployment.env"
  cp "$OPS_DIR/docker-compose.yml" "$BACKUP_PATH/docker-compose.yml"
  touch "$BACKUP_PATH/COMPLETE"
  printf '%s\n' "$BACKUP_PATH" > "$TOONFLOW_DATA_DIR/state/last-backup"
}
