#!/usr/bin/env bash
set -euo pipefail
umask 077
OPS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$OPS_DIR/.env"
action=${1:-status}
shift || true
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
valid_image() {
  [[ $1 =~ ^ghcr\.io/haipengtian/cloudreve(:[0-9]+\.[0-9]+\.[0-9]+-custom\.[1-9][0-9]*|@sha256:[a-f0-9]{64})$ ]]
}
valid_dir() {
  case "$1" in /|/opt|/srv|/var|/var/lib|/etc|/usr|/home|/root|/tmp) return 1 ;; esac
  [[ $1 =~ ^/([a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+$ && $1 != *'..'* && $(realpath -m -- "$1") == "$1" ]]
}
compose() { docker compose --project-directory "$OPS_DIR" --env-file "$ENV_FILE" -f "$OPS_DIR/compose.yaml" -p "$COMPOSE_PROJECT_NAME" "$@"; }
set_config() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp "$OPS_DIR/.env.XXXXXX")
  if ! awk -v key="$key" -v value="$value" 'index($0,key "=")==1 {$0=key "=" value; n++} {print} END {if(n!=1) exit 1}' "$ENV_FILE" > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  mv -f -- "$tmp" "$ENV_FILE"
  export "$key=$value"
}
load_env() {
  [[ -f $ENV_FILE && ! -L $ENV_FILE ]] || die '缺少常规 .env 文件，请先 install.sh'
  local line key value required
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die '.env 格式应为 KEY=value'
    key=${line%%=*}; value=${line#*=}
    case "$key" in CLOUDREVE_IMAGE|CLOUDREVE_HOST_PORT|CLOUDREVE_DATA_DIR|CLOUDREVE_BACKUP_DIR|COMPOSE_PROJECT_NAME|TZ) ;; *) die "未知配置键：$key" ;; esac
    [[ ! ${seen[$key]+set} && -n $value && $value != *[\ \$\`\"\'\\]* ]] || die "配置 $key 必须为非空、不重复的字面值"
    seen[$key]=1
    export "$key=$value"
  done < "$ENV_FILE"
  for required in CLOUDREVE_IMAGE CLOUDREVE_HOST_PORT CLOUDREVE_DATA_DIR CLOUDREVE_BACKUP_DIR COMPOSE_PROJECT_NAME TZ; do
    [[ ${seen[$required]+set} ]] || die "缺少配置 $required"
  done
  valid_image "$CLOUDREVE_IMAGE" || die '仅支持个人 GHCR 固定 custom 版本或摘要'
  [[ $CLOUDREVE_HOST_PORT =~ ^[0-9]{4,5}$ ]] || die '端口必须在1024—65535之间'
  ((10#$CLOUDREVE_HOST_PORT >= 1024 && 10#$CLOUDREVE_HOST_PORT <= 65535)) || die '端口必须在1024—65535之间'
  if ! valid_dir "$CLOUDREVE_DATA_DIR" || ! valid_dir "$CLOUDREVE_BACKUP_DIR"; then
    die '数据和备份路径需为独立绝对目录，不经过符号链接'
  fi
  [[ $CLOUDREVE_DATA_DIR != "$CLOUDREVE_BACKUP_DIR" && $CLOUDREVE_BACKUP_DIR != "$CLOUDREVE_DATA_DIR/"* && $CLOUDREVE_DATA_DIR != "$CLOUDREVE_BACKUP_DIR/"* ]] || die '数据和备份目录不能互相包含'
  [[ $COMPOSE_PROJECT_NAME =~ ^[a-z][a-z0-9_-]{2,40}$ && $TZ =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die '项目名称或时区无效'
}
wait_app() { compose up -d --no-deps --wait --wait-timeout 180 cloudreve; }
cid() { compose ps -a -q cloudreve; }
active_image() {
  local container
  container=$(cid)
  [[ -n $container ]] || die '容器不存在，请先 install.sh'
  docker inspect --format '{{.Config.Image}}' "$container"
}
resolved_image() {
  local resolved
  resolved=$(docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -m1 '^ghcr.io/haipengtian/cloudreve@sha256:')
  valid_image "$resolved" || die '无法取得已拉取镜像的 GHCR 摘要'
  printf '%s\n' "$resolved"
}
backup_data() {
  local image=$1
  mkdir -p -- "$CLOUDREVE_BACKUP_DIR" || return 1
  BACKUP_PATH=$(mktemp -d "$CLOUDREVE_BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
  tar -C "$CLOUDREVE_DATA_DIR" -czf "$BACKUP_PATH/data.tar.gz" . || return 1
  cp -- "$ENV_FILE" "$BACKUP_PATH/deployment.env" || return 1
  printf '%s\n' "$image" > "$BACKUP_PATH/image-ref" || return 1
  printf '停机备份：%s\n' "$BACKUP_PATH"
}
[[ $(id -u) == 0 ]] || die '请用 sudo 或 root 执行'
case "$action" in install|update|backup|restore|status|port) ;; *) die '用法：manage.sh install|status|backup|update 镜像|restore 备份目录' ;; esac
for cmd in docker flock realpath tar; do command -v "$cmd" >/dev/null || die "缺少 $cmd"; done
exec 9>"$OPS_DIR/.operation.lock"
flock -n 9 || die '另一个部署操作正在运行'
if [[ $action == install && ! -e $ENV_FILE && ! -L $ENV_FILE ]]; then cp "$OPS_DIR/.env.example" "$ENV_FILE"; fi
load_env
if [[ $action == port ]]; then printf '%s\n' "$CLOUDREVE_HOST_PORT"; exit 0; fi
docker info >/dev/null
compose config --quiet
case "$action" in
  status)
    compose ps -a
    compose logs --tail 25 cloudreve
    ;;
  install)
    [[ -z $(cid) ]] || die '已有容器，使用 update.sh，不重新安装'
    [[ ! -d $CLOUDREVE_DATA_DIR || -z $(ls -A -- "$CLOUDREVE_DATA_DIR") ]] || die '首次安装只接受空数据目录，不覆盖已有数据'
    compose pull cloudreve
    next=$(resolved_image "$CLOUDREVE_IMAGE")
    mkdir -p -- "$CLOUDREVE_DATA_DIR" "$CLOUDREVE_BACKUP_DIR"
    chown 0:0 -- "$CLOUDREVE_DATA_DIR" "$CLOUDREVE_BACKUP_DIR"
    chmod 700 -- "$CLOUDREVE_DATA_DIR" "$CLOUDREVE_BACKUP_DIR"
    set_config CLOUDREVE_IMAGE "$next"
    if ! wait_app; then compose stop cloudreve; die '首次启动失败，数据已保留；执行 status.sh 查看日志'; fi
    printf 'Cloudreve 已在 127.0.0.1:%s 就绪。先通过 SSH 隧道注册首个管理员，再开放域名。\n' "$CLOUDREVE_HOST_PORT"
    ;;
  update|backup)
    old=$(active_image)
    valid_image "$old" || die '运行中的容器不是个人 Cloudreve 镜像'
    [[ $(docker inspect --format '{{.State.Running}}' "$(cid)") == true ]] || die '应用未运行，先检查上次故障'
    if [[ $action == update ]]; then
      [[ $# == 1 ]] || die '用法：update.sh ghcr.io/haipengtian/cloudreve:固定版本'
      valid_image "$1" || die '目标镜像必须是个人固定版本或摘要'
      CLOUDREVE_IMAGE="$1" compose pull cloudreve
      next=$(resolved_image "$1")
      if [[ $old == "$next" ]]; then echo '当前已是目标镜像'; exit 0; fi
    fi
    compose stop cloudreve
    if ! backup_data "$old"; then
      compose start cloudreve || true
      die '备份失败，未切换镜像；检查空间、权限及旧容器状态'
    fi
    if [[ $action == update ]]; then set_config CLOUDREVE_IMAGE "$next"; fi
    if ! wait_app; then
      compose stop cloudreve
      die "启动未通过健康检查，保持暂停并保留数据。备份：$BACKUP_PATH；恢复：sudo bash restore.sh $BACKUP_PATH"
    fi
    echo '服务健康；请再验证登录、文件上传和读取。'
    ;;
  restore)
    [[ $# == 1 ]] || die '用法：restore.sh 备份目录'
    backup=$(realpath -e -- "$1")
    [[ $backup == "$CLOUDREVE_BACKUP_DIR/"* && -f $backup/data.tar.gz && -f $backup/image-ref ]] || die '请选择本服务备份目录中的完整备份'
    IFS= read -r previous < "$backup/image-ref"
    valid_image "$previous" || die '备份镜像引用无效'
    CLOUDREVE_IMAGE="$previous" compose pull cloudreve
    restored="${CLOUDREVE_DATA_DIR}.restore-$(date -u +%Y%m%dT%H%M%SZ)"
    [[ ! -e $restored ]] || die '恢复目录已存在'
    mkdir -- "$restored"
    tar -C "$restored" -xzf "$backup/data.tar.gz"
    compose stop cloudreve
    cp "$ENV_FILE" "$OPS_DIR/.env.before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    set_config CLOUDREVE_DATA_DIR "$restored"
    set_config CLOUDREVE_IMAGE "$previous"
    if ! wait_app; then compose stop cloudreve; die '恢复启动失败，原数据目录仍完整保留，请查看日志'; fi
    echo '已从备份启动，原数据目录未覆盖。备份时点后的新记录不在本次恢复内。'
    ;;
esac
