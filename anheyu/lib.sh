#!/usr/bin/env bash
OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export OPS_DIR
BACKUP_FILES=(database.dump redis.rdb files.tar.gz deployment.env docker-compose.images.yml source-compose.yml counts.tsv)
COUNTS_SQL="SELECT 'users',count(*) FROM users UNION ALL SELECT 'articles',count(*) FROM articles UNION ALL SELECT 'essays',count(*) FROM essays;"
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $(id -u) == 0 ]] || die '请用 root 或 sudo 执行'; }
require_commands() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done
}
check_docker() {
  require_commands docker flock realpath tar sha256sum
  docker info >/dev/null 2>&1 || die 'Docker daemon 不可用'
  docker compose version >/dev/null || die '需要 Docker Compose 插件'
}
lock_operation() {
  exec 9>"$1"
  flock -n 9 || die '另一个博客迁移操作正在进行'
}
compose() {
  local args=(--project-directory "$DEPLOY_ROOT" --env-file "$ENV_FILE" -p anheyu -f "$COMPOSE_FILE")
  if [[ -n ${IMAGES_FILE:-} ]]; then args+=(-f "$IMAGES_FILE"); fi
  docker compose "${args[@]}" "$@"
}
validate_image() {
  local repo=$1 image=$2
  [[ $image =~ ^($repo|docker\.io/library/$repo)@sha256:[a-f0-9]{64}$ ]] || die "无法确认 $repo 的固定镜像摘要"
}
active_digest() {
  local service=$1 repo=$2 cid image_id digest
  cid=$(compose ps -a -q "$service")
  [[ -n $cid ]] || die "找不到旧服务容器：$service"
  image_id=$(docker inspect "$cid" --format '{{.Image}}')
  digest=$(docker image inspect "$image_id" --format '{{range .RepoDigests}}{{println .}}{{end}}' |
    awk -v repo="$repo" 'index($0,repo "@sha256:")==1 || index($0,"docker.io/library/" repo "@sha256:")==1 {print; exit}')
  validate_image "$repo" "$digest"
  printf '%s\n' "$digest"
}
table_counts() { compose exec -T postgres psql -U anheyu -d anheyu -At -F '|' -c "$COUNTS_SQL"; }
check_backup() {
  local backup=$1 name index=0 line
  local -a sums
  [[ -d $backup && ! -e $backup/FAILED ]] || die '备份不存在或已标记失败'
  for name in "${BACKUP_FILES[@]}" SHA256SUMS; do
    [[ -f $backup/$name && ! -L $backup/$name ]] || die "备份缺少普通文件：$name"
  done
  mapfile -t sums < "$backup/SHA256SUMS"
  ((${#sums[@]} == ${#BACKUP_FILES[@]})) || die '备份校验清单无效'
  for name in "${BACKUP_FILES[@]}"; do
    line=${sums[$index]}
    [[ ${line:0:64} =~ ^[a-f0-9]{64}$ && ${line:64} == "  $name" ]] || die '备份校验清单无效'
    index=$((index + 1))
  done
  (cd "$backup" && sha256sum -c --status SHA256SUMS) || die '备份校验失败，请重新传输完整备份'
  tar -tzf "$backup/files.tar.gz" >/dev/null || die '文件归档不可读取'
}
deployment_port() {
  compose config --format json | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["anheyu"]["ports"]
assert len(ports) == 1 and ports[0]["host_ip"] == "127.0.0.1" and ports[0]["target"] == 8091
port = int(ports[0]["published"])
assert 1024 <= port <= 65535
print(port)
'
}
verify_http() {
  local port=$1
  local opts=(--noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 10
    --retry 30 --retry-all-errors --retry-connrefused --retry-delay 2)
  curl "${opts[@]}" "http://127.0.0.1:$port/" >/dev/null || return 1
  curl "${opts[@]}" "http://127.0.0.1:$port/api/public/essays" | python3 -c '
import json, sys
body = json.load(sys.stdin)
assert body.get("code") == 200 and isinstance(body.get("data"), dict)
' || return 1
}
