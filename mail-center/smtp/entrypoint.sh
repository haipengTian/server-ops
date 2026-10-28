#!/bin/sh
set -eu
valid_domain() {
  printf '%s\n' "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
}
valid_domain "${RECEIVE_DOMAIN:-}" && valid_domain "${MX_HOSTNAME:-}" || {
  echo 'Invalid receive domain or MX hostname' >&2; exit 1;
}
test -s /certs/fullchain.pem && test -s /certs/privkey.pem || {
  echo 'SMTP certificate is missing; run enable-smtp.sh first' >&2; exit 1;
}
postconf -e "myhostname = $MX_HOSTNAME"
postconf -e 'mydestination ='
postconf -e 'alias_maps ='
postconf -e 'alias_database ='
postconf -e 'inet_interfaces = all'
postconf -e 'inet_protocols = ipv4'
postconf -e 'mynetworks = 127.0.0.0/8'
postconf -e "relay_domains = $RECEIVE_DOMAIN"
postconf -e 'parent_domain_matches_subdomains = debug_peer_list,fast_flush_domains,mynetworks,permit_mx_backup_networks,qmqpd_authorized_clients,smtpd_access_maps'
postconf -e 'relay_recipient_maps ='
postconf -e 'smtpd_relay_restrictions = reject_unauth_destination'
postconf -e 'smtpd_recipient_restrictions = reject_unauth_destination'
postconf -e 'smtpd_helo_required = yes'
postconf -e 'transport_maps = static:smtp:[api]:2525'
postconf -e 'smtp_tls_security_level = none'
postconf -e 'smtpd_tls_security_level = may'
postconf -e 'smtpd_tls_cert_file = /certs/fullchain.pem'
postconf -e 'smtpd_tls_key_file = /certs/privkey.pem'
postconf -e 'message_size_limit = 26214400'
postconf -e 'smtpd_client_connection_rate_limit = 30'
postconf -e 'maillog_file = /dev/stdout'
postconf -e 'readme_directory = no'
postconf -e 'html_directory = no'
postfix set-permissions
postfix check
exec postfix start-fg
