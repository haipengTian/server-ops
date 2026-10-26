#!/usr/bin/env bash
# 仅恢复到从未部署博客的新机；失败保留文件、数据库和 Redis 卷。
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# -ge 1 && $# -le 2 ]] || die '用法：sudo bash anheyu/restore.sh <完整备份目录> [/opt/anheyu]'
check_docker
require_commands python3 ss curl cmp
backup=$(realpath -e -- "$1")
check_backup "$backup"
DEPLOY_ROOT=$(realpath -m -- "${2:-/opt/anheyu}")
[[ ! -e $DEPLOY_ROOT && ! -L $DEPLOY_ROOT ]] || die '目标目录已存在，拒绝覆盖；此入口仅用于新机首次恢复'
lock_operation "$DEPLOY_ROOT.migration.lock"
ENV_FILE="$backup/deployment.env"
COMPOSE_FILE="$OPS_DIR/docker-compose.prod.yml"
IMAGES_FILE="$backup/docker-compose.images.yml"
compose config --quiet
mapfile -t images < <(compose config --images)
[[ ${#images[@]} == 3 ]] || die '备份必须包含三个固定镜像'
app_found=false; pg_found=false; redis_found=false
for image in "${images[@]}"; do
  case "$image" in
    ghcr.io/haipengtian/anheyu-app@*) validate_image ghcr.io/haipengtian/anheyu-app "$image"; app_found=true ;;
    postgres@*|docker.io/library/postgres@*) validate_image postgres "$image"; pg_found=true ;;
    redis@*|docker.io/library/redis@*) validate_image redis "$image"; redis_found=true; redis_image=$image ;;
    *) die '备份镜像仓库与博客部署不符' ;;
  esac
done
[[ $app_found == true && $pg_found == true && $redis_found == true ]] || die '备份缺少博客、数据库或 Redis 镜像'
[[ -z $(compose ps -a -q) ]] || die 'anheyu 项目已有容器，拒绝覆盖'
for volume in anheyu_pgdata anheyu_redisdata; do
  if docker volume inspect "$volume" >/dev/null 2>&1; then die "已有数据卷 $volume，拒绝覆盖"; fi
done
port=$(deployment_port)
if ss -H -ltn "sport = :$port" | grep -q .; then die "本机端口 $port 已被占用"; fi
compose pull
mkdir -m 700 "$DEPLOY_ROOT"
target_started=false
completed=false
finish_restore() {
  local status=$?
  trap - EXIT
  if [[ $completed != true ]]; then
    if [[ $target_started == true ]]; then
      if ! compose stop; then printf '无法确认新机容器已暂停，请立即检查 Docker 状态。\n' >&2; fi
    fi
    touch "$DEPLOY_ROOT/MIGRATION_FAILED"
    printf '恢复未完成，已恢复的文件及数据卷保留在新机，请检查现场，不要清空数据或重新初始化。\n' >&2
    status=1
  fi
  exit "$status"
}
trap finish_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$backup/deployment.env" "$DEPLOY_ROOT/.env"
cp "$COMPOSE_FILE" "$DEPLOY_ROOT/docker-compose.prod.yml"
cp "$IMAGES_FILE" "$DEPLOY_ROOT/docker-compose.images.yml"
cp "$backup/counts.tsv" "$DEPLOY_ROOT/counts-original.tsv"
chmod 600 "$DEPLOY_ROOT/.env" "$DEPLOY_ROOT/docker-compose.images.yml"
tar -xzf "$backup/files.tar.gz" -C "$DEPLOY_ROOT"
ENV_FILE="$DEPLOY_ROOT/.env"
COMPOSE_FILE="$DEPLOY_ROOT/docker-compose.prod.yml"
IMAGES_FILE="$DEPLOY_ROOT/docker-compose.images.yml"
target_started=true
compose create redis
docker run --rm --network none --mount type=volume,source=anheyu_redisdata,target=/data \
  -v "$backup:/migration:ro,Z" --entrypoint sh "$redis_image" \
  -c 'cp /migration/redis.rdb /data/dump.rdb && chown redis:redis /data/dump.rdb'
compose up -d --wait --wait-timeout 180 postgres redis
compose exec -T postgres pg_restore -U anheyu -d anheyu --exit-on-error --single-transaction \
  --no-owner --no-privileges < "$backup/database.dump"
table_counts > "$DEPLOY_ROOT/counts-restored.tsv"
cmp -s "$DEPLOY_ROOT/counts-original.tsv" "$DEPLOY_ROOT/counts-restored.tsv" || die '恢复后的账号、文章或短文数量不一致'
compose up -d --no-deps --wait --wait-timeout 180 anheyu
verify_http "$port"
touch "$DEPLOY_ROOT/MIGRATION_COMPLETE"
completed=true
printf '博客已恢复至 %s，监听 127.0.0.1:%s；账号、文章与短文数量一致。\n' "$DEPLOY_ROOT" "$port"
printf '请使用原管理员账号，验证文章和附件后，再切换 blog.thpvip.xyz 的 DNS 和公共 Nginx。\n'
