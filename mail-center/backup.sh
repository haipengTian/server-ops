#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_docker
install -d -m 700 "$OPS_DIR/backups"
backup_dir=$(mktemp -d "$OPS_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mapfile -t running < <(compose --profile smtp ps --status running --services | grep -E '^(api|smtp|gateway)$' || true)
resume() {
  local result=$?
  trap - EXIT
  if ((${#running[@]})); then
    compose --profile smtp start --wait --wait-timeout 120 "${running[@]}" || result=1
  fi
  if ((result)); then printf '备份或服务恢复失败，请检查状态；临时文件保留在 %s。\n' "$backup_dir" >&2; fi
  exit "$result"
}
trap resume EXIT
if ((${#running[@]})); then compose --profile smtp stop "${running[@]}"; fi
compose exec -T postgres pg_dump -U mail_center -d mail_center -Fc > "$backup_dir/database.dump"
cp "$ENV_FILE" "$backup_dir/environment"
tar --numeric-owner --exclude='smtp-queue/private' --exclude='smtp-queue/public' --exclude='smtp-queue/pid' -czf "$backup_dir/files.tar.gz" -C "$OPS_DIR/data" mail smtp-queue smtp-tls
compose --profile smtp images --format json > "$backup_dir/images.json"
tar -czf "$backup_dir.tar.gz" -C "$backup_dir" database.dump environment files.tar.gz images.json
chmod 600 "$backup_dir.tar.gz"
printf '备份完成：%s.tar.gz（含凭据和加密密钥，请妥善保管并另存一份）。\n' "$backup_dir"
