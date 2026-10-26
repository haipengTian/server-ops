#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 0 || $# == 1 && $1 == --initial ]] || die '用法：bash verify.sh [--initial]'
load_env
verify_http
check_settings "${1:-}"
printf '网页、健康接口及匿名访问限制检查通过。\n'
