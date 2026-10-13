#!/usr/bin/env bash
set -euo pipefail
# Certbot 续期成功后验证并重载，使 nginx 使用新的证书。
nginx -t
systemctl reload nginx
