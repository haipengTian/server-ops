#!/usr/bin/env bash
# 迁移快照：成功后保持旧应用停止，数据库和 Redis 继续运行。
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# -le 1 ]] || die '用法：sudo bash anheyu/backup.sh [/opt/anheyu]'
check_docker
DEPLOY_ROOT=$(realpath -e -- "${1:-/opt/anheyu}")
ENV_FILE="$DEPLOY_ROOT/.env"
COMPOSE_FILE="$DEPLOY_ROOT/docker-compose.prod.yml"
IMAGES_FILE=
if [[ -f $DEPLOY_ROOT/docker-compose.images.yml ]]; then IMAGES_FILE="$DEPLOY_ROOT/docker-compose.images.yml"; fi
[[ -f $ENV_FILE && -f $COMPOSE_FILE ]] || die '旧部署目录缺少 .env 或 docker-compose.prod.yml'
lock_operation "$DEPLOY_ROOT/.migration.lock"
compose config --quiet
app_cid=$(compose ps -a -q anheyu)
[[ -n $app_cid ]] || die '找不到旧博客容器'
for name in data themes static backup; do
  [[ -d $DEPLOY_ROOT/$name && ! -L $DEPLOY_ROOT/$name ]] || die "缺少实际文件目录：$name"
  mounted=$(docker inspect "$app_cid" --format "{{range .Mounts}}{{if eq .Destination \"/anheyu/$name\"}}{{.Source}}{{end}}{{end}}")
  [[ $mounted == "$DEPLOY_ROOT/$name" ]] || die "实际 $name 挂载与部署目录不一致，请先核对"
done
app_image=$(active_digest anheyu ghcr.io/haipengtian/anheyu-app)
pg_image=$(active_digest postgres postgres)
redis_image=$(active_digest redis redis)
mkdir -p "$DEPLOY_ROOT/migration-backups"
chmod 700 "$DEPLOY_ROOT/migration-backups"
backup=$(mktemp -d "$DEPLOY_ROOT/migration-backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
was_running=$(compose ps --status running -q anheyu)
completed=false
finish_backup() {
  local status=$?
  trap - EXIT
  if [[ $completed != true ]]; then
    touch "$backup/FAILED"
    if [[ -n $was_running ]]; then
      compose up -d --no-recreate --no-deps --pull never --wait --wait-timeout 180 anheyu || status=1
    fi
    printf '备份失败，现场保留在 %s；已尝试恢复旧应用原运行状态。\n' "$backup" >&2
    status=1
  fi
  exit "$status"
}
trap finish_backup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$ENV_FILE" "$backup/deployment.env"
cp "$COMPOSE_FILE" "$backup/source-compose.yml"
cat > "$backup/docker-compose.images.yml" <<IMAGES
services:
  anheyu:
    image: $app_image
  postgres:
    image: $pg_image
  redis:
    image: $redis_image
IMAGES
compose stop anheyu
compose exec -T postgres pg_dump -U anheyu -d anheyu -Fc --no-owner --no-privileges > "$backup/database.dump"
table_counts > "$backup/counts.tsv"
# RDB 包含原 Redis 数据与过期时间；密码由容器内环境读取，不出现在命令参数或输出。
# shellcheck disable=SC2016
compose exec -T redis sh -c '
set -eu
umask 077
snapshot=$(mktemp /tmp/anheyu-redis-XXXXXX)
trap '\''rm -f -- "$snapshot"'\'' EXIT
REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --rdb "$snapshot" >/dev/null
cat "$snapshot"
' > "$backup/redis.rdb"
tar -czf "$backup/files.tar.gz" -C "$DEPLOY_ROOT" data themes static backup
(cd "$backup" && sha256sum "${BACKUP_FILES[@]}" > SHA256SUMS)
chmod 600 "$backup/"*
check_backup "$backup"
printf '%s\n' "$backup" > "$DEPLOY_ROOT/migration-backups/last-backup"
completed=true
printf '备份完成：%s\n旧博客应用保持停止，转移期间请勿恢复写入；数据库和 Redis 保持运行。\n' "$backup"
