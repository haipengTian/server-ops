#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "$0")"
OPS_DIR=$PWD

die() { printf '%s\n' "$*" >&2; exit 1; }
image_ok() { [[ $1 =~ ^ghcr\.io/haipengtian/maibot-qq:sha-[a-f0-9]{12}$ ]] || die 'Use the verified sha image tag printed by GitHub Actions.'; }
load_env() {
  [[ -f .env ]] || die 'First run: bash deploy.sh prepare <image>'
  # This is the operator-owned deployment configuration, never a downloaded script.
  set -a
  # shellcheck source=/dev/null
  source ./.env
  set +a
  image_ok "$MAIBOT_IMAGE"
  [[ $MAIBOT_DATA_DIR == /opt/maibot-qq ]] || die 'Expected data directory /opt/maibot-qq.'
}
compose() { docker compose --env-file "$OPS_DIR/.env" -f "$OPS_DIR/compose.yaml" "$@"; }
command -v docker >/dev/null || die 'Install Docker with the Compose v2 plugin first.'
docker compose version >/dev/null
[[ $(docker info --format '{{.Architecture}}') == x86_64 ]] || die 'This image is built for the existing amd64 server.'
command=${1:-help}
shift || true
case "$command" in
  prepare)
    [[ $# == 1 ]] || die 'Usage: bash deploy.sh prepare ghcr.io/haipengtian/maibot-qq:sha-<12 digits>'
    image_ok "$1"
    if [[ -e .env ]]; then
      load_env
      [[ $MAIBOT_IMAGE == "$1" ]] || die '.env already selects another release; do not overwrite it.'
    else
      sed "s|^MAIBOT_IMAGE=.*|MAIBOT_IMAGE=$1|" .env.example > .env
      chmod 600 .env
      load_env
    fi
    compose config --quiet
    compose pull
    printf 'Images ready. Import the final private migration archive next. No services started.\n'
    ;;
  import)
    load_env
    [[ $# == 1 && -f $1 ]] || die 'Usage: bash deploy.sh import /root/maibot-final.tar.gz'
    archive=$(realpath -- "$1")
    [[ ! -e $MAIBOT_DATA_DIR ]] || die 'Data directory already exists; import never overwrites an instance.'
    restore_dir=$(mktemp -d /opt/.maibot-restore.XXXXXX)
    chmod 700 "$restore_dir"
    # Relabel only a dedicated staging directory, never the shared /opt tree.
    docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python \
      -v "$archive:/migration/input.tar.gz:ro,Z" \
      -v "$restore_dir:/restore:Z" "$MAIBOT_IMAGE" /opt/deploy/migrate.py import \
      --archive /migration/input.tar.gz --target /restore/maibot-qq
    mv -T -- "$restore_dir/maibot-qq" "$MAIBOT_DATA_DIR"
    rmdir -- "$restore_dir"
    ;;
  start)
    load_env
    [[ ${1:-} == --local-stopped ]] || die 'Stop local MaiBot and SnowLuma first, then: bash deploy.sh start --local-stopped'
    [[ -f $MAIBOT_DATA_DIR/migration.json ]] || die 'Import the private instance before starting.'
    compose up -d --wait --wait-timeout 300
    curl --fail --silent --show-error "http://127.0.0.1:${MAIBOT_WEB_PORT}/api/webui/health"
    printf '\nContainers ready. Check QQ login, connected account and allowlist in the dashboard.\n'
    ;;
  status)
    load_env
    compose ps
    curl --fail --silent --show-error "http://127.0.0.1:${MAIBOT_WEB_PORT}/api/webui/health"
    printf '\n'
    ;;
  stop)
    load_env
    compose stop
    ;;
  backup)
    load_env
    [[ -d $MAIBOT_DATA_DIR/runtime ]] || die 'No instance to back up.'
    compose stop
    mkdir -p /opt/maibot-qq-backups
    chmod 700 /opt/maibot-qq-backups
    backup="/opt/maibot-qq-backups/instance-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    [[ ! -e $backup ]] || die 'Backup filename exists.'
    tar -C /opt -czf "$backup" maibot-qq
    cp -- .env "$backup.env"
    printf 'Backup saved: %s\nServices remain stopped. Restart with: bash deploy.sh start --local-stopped\n' "$backup"
    ;;
  *)
    die 'Commands: prepare IMAGE | import ARCHIVE | start --local-stopped | status | stop | backup'
    ;;
esac
