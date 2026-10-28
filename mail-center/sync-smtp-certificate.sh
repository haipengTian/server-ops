#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/lib.sh"
require_root
load_env
cert_dir="/etc/letsencrypt/live/$MX_HOSTNAME"
[[ -z ${RENEWED_LINEAGE:-} || $RENEWED_LINEAGE == "$cert_dir" ]] || exit 0
openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 0 >/dev/null || die 'SMTP 证书缺失或过期'
cmp <(openssl x509 -in "$cert_dir/fullchain.pem" -pubkey -noout) <(openssl pkey -in "$cert_dir/privkey.pem" -pubout) || die 'SMTP 证书与私钥不匹配'
install -d -m 700 "$OPS_DIR/data/smtp-tls"
install -m 644 "$cert_dir/fullchain.pem" "$OPS_DIR/data/smtp-tls/fullchain.pem.new"
install -m 600 "$cert_dir/privkey.pem" "$OPS_DIR/data/smtp-tls/privkey.pem.new"
mv -f "$OPS_DIR/data/smtp-tls/fullchain.pem.new" "$OPS_DIR/data/smtp-tls/fullchain.pem"
mv -f "$OPS_DIR/data/smtp-tls/privkey.pem.new" "$OPS_DIR/data/smtp-tls/privkey.pem"
if [[ -n $(compose --profile smtp ps --status running -q smtp) ]]; then
  compose exec -T smtp postfix reload
fi
