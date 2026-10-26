#!/usr/bin/env bash
# 仅在独占的临时 Docker daemon/CI runner 演练，不使用生产账号或数据。
set -euo pipefail
umask 077
# shellcheck source=../lib.sh
source "$(dirname -- "$0")/../lib.sh"
require_root
check_docker
require_commands openssl python3 curl cmp
[[ -z $(docker ps -aq --filter label=com.docker.compose.project=anheyu) ]] || die '演练要求不存在 anheyu 容器的独占环境'
for volume in anheyu_pgdata anheyu_redisdata; do
  if docker volume inspect "$volume" >/dev/null 2>&1; then die '演练要求不存在 anheyu 数据卷的独占环境'; fi
done
test_root=$(mktemp -d /tmp/anheyu-container-XXXXXXXX)
source_root="$test_root/source"
destination="$test_root/destination"
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -f $destination/docker-compose.images.yml ]]; then
    docker compose --project-directory "$destination" --env-file "$destination/.env" \
      -p anheyu -f "$destination/docker-compose.prod.yml" -f "$destination/docker-compose.images.yml" \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -f $source_root/.env ]]; then
    docker compose --project-directory "$source_root" --env-file "$source_root/.env" \
      -p anheyu -f "$source_root/docker-compose.prod.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ $test_root == /tmp/anheyu-container-* ]]; then rm -rf -- "$test_root"; fi
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$source_root"/{data,themes,static,backup}
cp "$OPS_DIR/docker-compose.prod.yml" "$source_root/"
cat > "$source_root/.env" <<ENV
ANHEYU_TAG=custom-8be703576a15fe7fa8a7d9d63735751555a33083
ANHEYU_PORT=8091
ANHEYU_DATABASE_PASSWORD=CiPg!$(openssl rand -hex 20)
ANHEYU_REDIS_PASSWORD=CiRedis!$(openssl rand -hex 20)
REVALIDATE_TOKEN=$(openssl rand -hex 32)
ENV
DEPLOY_ROOT=$source_root
ENV_FILE="$source_root/.env"
COMPOSE_FILE="$source_root/docker-compose.prod.yml"
IMAGES_FILE=
compose up -d --wait --wait-timeout 180
verify_http 8091
# 合成测试数据：不用注册管理员，不触及生产凭据。
compose exec -T postgres psql -v ON_ERROR_STOP=1 -U anheyu -d anheyu <<'SQL' >/dev/null
CREATE TABLE migration_fixture (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO migration_fixture VALUES (1, 'original-postgres-value');
INSERT INTO essays (created_at,updated_at,published_at,content) VALUES (now(),now(),now(),'migration-container-fixture');
INSERT INTO users (created_at,updated_at,username,password_hash,email,status,user_group_id)
SELECT now(),now(),'migration-fixture','invalid-test-login-hash','migration@example.invalid',1,id FROM user_groups ORDER BY id LIMIT 1;
SQL
# shellcheck disable=SC2016
compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli SET migration:fixture original-redis-value' >/dev/null
for name in data themes static backup; do printf 'original-%s\n' "$name" > "$source_root/$name/migration-fixture"; done
bash "$OPS_DIR/backup.sh" "$source_root"
bundle=$(cat "$source_root/migration-backups/last-backup")
[[ -z $(compose ps --status running -q anheyu) ]] || die '备份后旧应用仍在运行'
# 仅移除本演练创建的源容器/卷，模拟另一台全新服务器。
compose down --volumes --remove-orphans
bash "$OPS_DIR/restore.sh" "$bundle" "$destination"
DEPLOY_ROOT=$destination
ENV_FILE="$destination/.env"
COMPOSE_FILE="$destination/docker-compose.prod.yml"
IMAGES_FILE="$destination/docker-compose.images.yml"
cmp "$source_root/.env" "$destination/.env"
for name in data themes static backup; do cmp "$source_root/$name/migration-fixture" "$destination/$name/migration-fixture"; done
[[ $(compose exec -T postgres psql -U anheyu -d anheyu -Atc 'SELECT value FROM migration_fixture WHERE id=1;') == original-postgres-value ]]
[[ $(compose exec -T postgres psql -U anheyu -d anheyu -Atc "SELECT count(*) FROM users WHERE username='migration-fixture' AND password_hash='invalid-test-login-hash';") == 1 ]]
[[ $(compose exec -T postgres psql -U anheyu -d anheyu -Atc "SELECT count(*) FROM essays WHERE content='migration-container-fixture';") == 1 ]]
# shellcheck disable=SC2016
[[ $(compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli GET migration:fixture') == original-redis-value ]]
[[ -f $destination/MIGRATION_COMPLETE ]]
verify_http 8091
printf 'PASS: real container migration preserved PostgreSQL records, Redis value, credentials, four directories and HTTP readiness.\n'
