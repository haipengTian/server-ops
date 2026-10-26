#!/usr/bin/env bash
# 共享配置与部署事务；由入口脚本 source。
OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$OPS_DIR/.env"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $(id -u) == 0 ]] || die '请用 root 或 sudo 执行'; }
require_commands() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done
}
lock_operation() {
  require_commands flock
  exec 9>"$OPS_DIR/.operation.lock"
  flock -n 9 || die '另一个安装、备份或升级操作正在进行'
}
validate_image() {
  [[ $1 =~ ^ghcr\.io/haipengtian/cloudflare-imgbed(:[0-9]+\.[0-9]+\.[0-9]+-custom\.[0-9]+(-amd64|-arm64)?|@sha256:[a-f0-9]{64})$ ]] ||
    die '镜像必须是个人 GHCR 的固定 custom 版本或 sha256 摘要'
}
load_env() {
  [[ -f $ENV_FILE ]] || die '先运行 bash init.sh <个人镜像>'
  [[ ! -L $ENV_FILE ]] || die '.env 不能是符号链接'
  # .env 是数据，不当作 root shell 脚本执行。只接受已知键和字面值。
  local key value line
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die '.env 存在无效行，格式应为 KEY=value'
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      IMGBED_IMAGE|IMGBED_DOMAIN|IMGBED_HOST_PORT|IMGBED_DATA_DIR|IMGBED_WAIT_SECONDS|COMPOSE_PROJECT_NAME|BASIC_USER|BASIC_PASS|AUTH_CODE|AI_CONFIG_SECRET|CERTBOT_EMAIL|TZ|IMGBED_MEM_LIMIT|IMGBED_CPUS) ;;
      *) die "不支持的配置键：$key" ;;
    esac
    [[ ! ${seen[$key]+set} ]] || die "配置键重复：$key"
    seen[$key]=1
    # 统一限制为字面值，避免 Compose 的变量展开与 shell 读取不一致。
    [[ $value != *[\ \$\`\"\'\\]* ]] || die "配置 $key 不允许空格、引号、反斜杠或变量展开"
    export "$key=$value"
  done < "$ENV_FILE"
  local required
  for required in IMGBED_IMAGE IMGBED_DOMAIN IMGBED_HOST_PORT IMGBED_DATA_DIR IMGBED_WAIT_SECONDS COMPOSE_PROJECT_NAME BASIC_USER BASIC_PASS AUTH_CODE AI_CONFIG_SECRET TZ IMGBED_MEM_LIMIT IMGBED_CPUS; do
    [[ ${seen[$required]+set} && -n ${!required} ]] || die "请填写 .env 中的 $required"
  done
  validate_image "$IMGBED_IMAGE"
  [[ $IMGBED_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die '域名格式无效'
  [[ $IMGBED_HOST_PORT =~ ^[0-9]{2,5}$ ]] || die '应用端口应在 1024—65535 之间'
  ((10#$IMGBED_HOST_PORT >= 1024 && 10#$IMGBED_HOST_PORT <= 65535)) || die '应用端口应在 1024—65535 之间'
  [[ $IMGBED_WAIT_SECONDS =~ ^[0-9]{1,4}$ ]] || die '启动等待时间至少 30 秒'
  ((10#$IMGBED_WAIT_SECONDS >= 30)) || die '启动等待时间至少 30 秒'
  [[ $COMPOSE_PROJECT_NAME =~ ^[a-z][a-z0-9_-]{2,40}$ ]] || die 'Compose 项目名无效'
  [[ $IMGBED_DATA_DIR =~ ^/([a-zA-Z0-9_-]+/)*[a-zA-Z0-9_-]+$ ]] || die '数据目录必须是绝对路径且不能含空格或 ..'
  case "$IMGBED_DATA_DIR" in /|/opt|/var|/root|/home|/etc|/usr|/tmp|/var/lib) die '数据目录必须是专用子目录' ;; esac
  [[ $(realpath -m -- "$IMGBED_DATA_DIR") == "$IMGBED_DATA_DIR" ]] || die '数据目录不能经过符号链接'
  [[ $BASIC_USER =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || die '管理员用户名仅支持字母、数字、下划线和连字符'
  [[ $TZ =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die '时区格式无效'
  [[ $IMGBED_MEM_LIMIT =~ ^[1-9][0-9]*[mg]$ ]] || die 'IMGBED_MEM_LIMIT 应使用正整数加 m 或 g'
  [[ $IMGBED_CPUS =~ ^[0-9]+(\.[0-9]+)?$ && $IMGBED_CPUS =~ [1-9] ]] || die 'IMGBED_CPUS 应为正数'
  for key in BASIC_PASS AUTH_CODE AI_CONFIG_SECRET; do
    [[ ${!key} =~ ^[a-f0-9]{64}$ ]] || die "$key 须保留 init.sh 生成的 64 位十六进制值"
  done
  STATE_DIR="$IMGBED_DATA_DIR/state"
}
compose() { docker compose --project-directory "$OPS_DIR" --env-file "$ENV_FILE" -f "$OPS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT_NAME" "$@"; }
check_docker() {
  require_commands docker realpath tar sha256sum curl
  docker info >/dev/null 2>&1 || die 'Docker daemon 不可用'
  docker compose version >/dev/null || die '需要 Docker Compose 插件'
  local help
  help=$(compose up --help)
  grep -q -- --wait-timeout <<< "$help" || die 'Compose 版本过旧，需要支持 up --wait-timeout'
  compose config --quiet
}
set_config() {
  local key=$1 value=$2 temp
  temp=$(mktemp "$OPS_DIR/.env.XXXXXX") || return 1
  if ! { awk -v key="$key" -v value="$value" 'index($0,key "=")==1 {$0=key "=" value; n++} {print} END {if(n!=1) exit 1}' "$ENV_FILE" > "$temp" &&
         chmod 600 "$temp" && mv -f -- "$temp" "$ENV_FILE"; }; then
    rm -f -- "$temp"
    printf '无法更新 %s\n' "$key" >&2
    return 1
  fi
  export "$key=$value"
}
state_write() {
  local temp
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" || return 1
  temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$temp" && mv -f -- "$temp" "$STATE_DIR/$1"; }; then
    rm -f -- "$temp"
    return 1
  fi
}
image_digest() {
  local digest
  digest=$(docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' |
    awk '/^ghcr\.io\/haipengtian\/cloudflare-imgbed@sha256:[a-f0-9]+$/ {print; exit}')
  [[ -n $digest ]] || die '无法取得个人镜像摘要，请先确认镜像已发布到 GHCR'
  validate_image "$digest"
  printf '%s\n' "$digest"
}
active_image() {
  local cid
  cid=$(compose ps -a -q imgbed)
  [[ -n $cid ]] || die '没有已安装的应用容器，请先 install.sh'
  docker inspect "$cid" --format '{{.Config.Image}}'
}
wait_app() {
  # 调用方用 if ! wait_app 时 Bash 会禁用函数内的 errexit，必须显式检查。
  compose up -d --no-deps --wait --wait-timeout "$IMGBED_WAIT_SECONDS" imgbed || return 1
  verify_http
}
verify_http() {
  local base="http://127.0.0.1:$IMGBED_HOST_PORT" code
  # 读取容器中实际生效的持久化设置，阻止用户名存在但密码为空的管理员配置。
  compose exec -T imgbed node --import ./deploy/server/register.mjs deploy/server/readiness.js || return 1
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 "$base/" >/dev/null || return 1
  code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "$base/api/manage/list") || return 1
  [[ $code == 401 ]] || { printf '管理接口未拒绝匿名访问（HTTP %s）\n' "$code" >&2; return 1; }
  code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' -X POST "$base/upload") || return 1
  [[ $code == 401 ]] || { printf '上传接口未拒绝匿名访问（HTTP %s）\n' "$code" >&2; return 1; }
}
record_release() {
  state_write current-image "$IMGBED_IMAGE" || return 1
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$IMGBED_IMAGE" >> "$STATE_DIR/history.tsv"
}
# 在目标镜像首次启动前可恢复原容器；启动后数据库可能已迁移，必须暂停。
begin_app_transaction() {
  transaction_target=$1
  transaction_dir=$(mktemp -d "$OPS_DIR/.transaction.XXXXXX")
  transaction_phase=prepared
  transaction_original_env_image=$IMGBED_IMAGE
  transaction_was_running=$(compose ps --status running -q imgbed)
  cp "$ENV_FILE" "$transaction_dir/deployment.env"
  chmod 600 "$transaction_dir/deployment.env"
  if [[ -f $STATE_DIR/previous-image ]]; then
    cp "$STATE_DIR/previous-image" "$transaction_dir/previous-image"
  fi
  trap finish_app_transaction EXIT
}
finish_app_transaction() {
  local status=$?
  trap - EXIT
  if [[ $transaction_phase == paused ]]; then
    if mv -f -- "$transaction_dir/deployment.env" "$ENV_FILE"; then
      export IMGBED_IMAGE=$transaction_original_env_image
      if [[ -f $transaction_dir/previous-image ]]; then
        mv -f -- "$transaction_dir/previous-image" "$STATE_DIR/previous-image" || status=1
      else
        rm -f -- "$STATE_DIR/previous-image" || status=1
      fi
      if [[ -n $transaction_was_running ]]; then
        compose up -d --no-recreate --no-deps --pull never --wait --wait-timeout "$IMGBED_WAIT_SECONDS" imgbed || status=1
      fi
      printf '目标镜像尚未启动，已恢复原配置并尝试恢复原服务。\n' >&2
    else
      printf '原配置恢复失败；应用保持暂停，配置副本：%s/deployment.env\n' "$transaction_dir" >&2
      exit 1
    fi
  elif [[ $transaction_phase == target-starting ]]; then
    if ! compose stop imgbed; then
      printf '目标容器停止失败，无法确认应用已暂停；请立即检查 Docker 与容器状态。\n' >&2
      status=1
    fi
    state_write failed-upgrade "$transaction_target" || status=1
    printf '目标版本已尝试启动，本次上线取消。检查容器状态与迁移兼容性；备份：%s\n' "$BACKUP_PATH" >&2
  fi
  rm -rf -- "$transaction_dir"
  exit "$status"
}
create_backup() {
  local image=$1 dir app_running
  validate_image "$image"
  app_running=$(compose ps --status running -q imgbed) || return 1
  [[ -z $app_running ]] || { printf '备份前需要暂停应用写入\n' >&2; return 1; }
  mkdir -p "$IMGBED_DATA_DIR/backups" || return 1
  dir=$(mktemp -d "$IMGBED_DATA_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
  chmod 700 "$IMGBED_DATA_DIR/backups" "$dir" || return 1
  # 应用已停止，SQLite 主库、WAL 与本地对象保持同一时间点。
  if ! { tar -czf "$dir/data.tar.gz" -C "$IMGBED_DATA_DIR/app" . &&
         tar -tzf "$dir/data.tar.gz" >/dev/null &&
         cp "$ENV_FILE" "$dir/deployment.env" &&
         printf '%s\n' "$image" > "$dir/image" &&
         (cd "$dir" && sha256sum data.tar.gz deployment.env image > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null) &&
         chmod 600 "$dir"/* &&
         state_write last-backup "$dir"; }; then
    touch "$dir/FAILED"
    printf '备份失败，现场保留在 %s\n' "$dir" >&2
    return 1
  fi
  BACKUP_PATH="$dir"
  printf '备份完成：%s\n' "$dir"
}
