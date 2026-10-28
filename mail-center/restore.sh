#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
[[ $# == 1 && -f $1 ]] || die '用法：在全新部署目录执行 bash restore.sh /绝对路径/备份.tar.gz'
[[ ! -e $ENV_FILE ]] || die '仅允许恢复到没有 .env 的全新部署目录；保留现有服务'
[[ ! -e $OPS_DIR/data ]] || die '仅允许恢复到没有 data 的全新目录'
restore_dir=$(mktemp -d "$OPS_DIR/.restore-XXXXXX")
tar -tzf "$1" | LC_ALL=C sort > "$restore_dir/actual"
printf '%s\n' database.dump environment files.tar.gz images.json | LC_ALL=C sort > "$restore_dir/expected"
cmp -s "$restore_dir/actual" "$restore_dir/expected" || die '备份文件清单不正确'
tar -xzf "$1" -C "$restore_dir" --no-same-owner --no-same-permissions
[[ -f $restore_dir/environment && ! -L $restore_dir/environment ]] || die '备份配置不是普通文件'
tar -tzf "$restore_dir/files.tar.gz" | while IFS= read -r path; do
  [[ $path != /* && $path != *'..'* && $path =~ ^(mail|smtp-queue|smtp-tls)(/|$) ]] || die '备份数据路径不正确'
done
tar -tvzf "$restore_dir/files.tar.gz" | while IFS= read -r entry; do
  [[ $entry == -* || $entry == d* ]] || die '备份数据只允许普通文件和目录'
done
target_env=$ENV_FILE
ENV_FILE="$restore_dir/environment"
load_env
check_docker
[[ -z $(compose --profile smtp ps -q) ]] || die '同名 Compose 项目已存在，停止恢复'
ENV_FILE=$target_env
install -m 600 "$restore_dir/environment" "$ENV_FILE"
install -d -m 700 "$OPS_DIR/data" "$OPS_DIR/data/postgres" "$OPS_DIR/backups"
tar -xzf "$restore_dir/files.tar.gz" -C "$OPS_DIR/data" --numeric-owner
compose up -d --wait --wait-timeout 120 postgres
compose exec -T postgres pg_restore -U mail_center -d mail_center --exit-on-error < "$restore_dir/database.dump"
printf '数据恢复完成，应用尚未启动。运行 bash install.sh，再检查登录和邮件。\n'
printf '原镜像记录：%s/images.json；请保留恢复临时目录直至验证完成。\n' "$restore_dir"
