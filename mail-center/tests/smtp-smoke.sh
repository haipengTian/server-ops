#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 1 ]] || { echo 'Usage: smtp-smoke.sh image' >&2; exit 1; }
scratch=$(mktemp -d)
name="mail-smtp-ci-$(basename "$scratch" | tr '[:upper:].' '[:lower:]-')"
cleanup() {
  local result=$?
  trap - EXIT
  if ((result)); then docker logs --tail 60 "$name-smtp" >&2 || true; fi
  docker rm -f "$name-smtp" "$name-sink" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
  docker volume rm "$name-queue" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
  exit "$result"
}
trap cleanup EXIT
mkdir "$scratch/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mx.example.com \
  -keyout "$scratch/tls/privkey.pem" -out "$scratch/tls/fullchain.pem" 2>/dev/null
docker network create "$name" >/dev/null
docker volume create "$name-queue" >/dev/null
docker run -d --name "$name-sink" --network "$name" --network-alias api \
  -e MP_SMTP_BIND_ADDR=0.0.0.0:2525 --publish 127.0.0.1::8025 \
  axllent/mailpit:v1.27 >/dev/null
docker run -d --name "$name-smtp" --network "$name" --publish 127.0.0.1::25 \
  --mount "type=volume,source=$name-queue,target=/var/spool/postfix" \
  --mount "type=bind,source=$scratch/tls,target=/certs,readonly" \
  -e RECEIVE_DOMAIN=inbox.example.com -e MX_HOSTNAME=mx.example.com "$1" >/dev/null
ready=false
for attempt in {1..60}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$name-smtp") == true ]] && docker exec "$name-smtp" postfix status >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]]
smtp_port=$(docker port "$name-smtp" 25/tcp | cut -d: -f2)
http_port=$(docker port "$name-sink" 8025/tcp | cut -d: -f2)
python3 - "$smtp_port" <<'PY'
import smtplib, ssl, sys
from email.message import EmailMessage
with smtplib.SMTP('127.0.0.1', int(sys.argv[1]), timeout=15) as smtp:
    smtp.ehlo()
    assert smtp.has_extn('starttls')
    smtp.starttls(context=ssl._create_unverified_context())
    smtp.ehlo()
    message = EmailMessage()
    message['From'] = 'fixture@example.com'
    message['To'] = 'inbox@inbox.example.com'
    message['Subject'] = 'CI Postfix fixture'
    message.set_content('Disposable SMTP integration fixture.')
    smtp.send_message(message)
with smtplib.SMTP('127.0.0.1', int(sys.argv[1]), timeout=15) as smtp:
    smtp.ehlo()
    smtp.mail('fixture@example.com')
    for recipient in ['a@outside.example.com', 'a@sub.inbox.example.com']:
        code, _ = smtp.rcpt(recipient)
        assert code in (550, 554), (recipient, code)
PY
delivered=false
for attempt in {1..30}; do
  if curl -fsS "http://127.0.0.1:$http_port/api/v1/messages" > "$scratch/messages.json" && \
    python3 - "$scratch/messages.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    messages = json.load(source)
assert any(item['Subject'] == 'CI Postfix fixture' for item in messages['messages'])
PY
  then delivered=true; break; fi
  sleep 1
done
[[ $delivered == true ]]
echo 'SMTP STARTTLS, exact-domain routing and relay checks passed.'
