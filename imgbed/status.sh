#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
load_env
compose ps
for name in current-image previous-image last-backup failed-upgrade failed-install; do
  [[ ! -f $STATE_DIR/$name ]] || printf '%s：%s\n' "$name" "$(cat "$STATE_DIR/$name")"
done
