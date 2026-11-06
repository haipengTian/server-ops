#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 ]] || { echo '用法：sudo bash setup-nginx.sh 证书通知邮箱' >&2; exit 1; }
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
port=$(bash "$root/cloudreve/manage.sh" port)
# Run only after the first administrator was created through the SSH tunnel.
exec bash "$root/nginx/add-site.sh" --domain cloud.thpvip.xyz --upstream "http://127.0.0.1:$port" --email "$1"
