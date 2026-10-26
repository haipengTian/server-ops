#!/usr/bin/env bash
# Managed by server-ops/nginx
set -euo pipefail
# Certbot 成功续期后，新 nginx worker 才会读取更新后的证书。
if systemctl is-active --quiet nginx; then
  nginx -t
  systemctl reload nginx
fi
