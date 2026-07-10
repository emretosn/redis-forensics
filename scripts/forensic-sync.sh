#!/usr/bin/env bash
# forensic-sync.sh
# Export in-memory forensic artifacts, then push everything to the forensics collector VM.
# (Section VI: preserve AOF & RDB; ACL LOG needs periodic exporting for retention.)
# Run on a systemd timer. Uses rsync over SSH with a dedicated collector key.
set -euo pipefail

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"
FORENSICS_DIR="${FORENSICS_DIR:-/var/forensics}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_LOG_DIR="${REDIS_LOG_DIR:-/var/log/redis}"

COLLECTOR_USER="${COLLECTOR_USER:-collector}"
COLLECTOR_HOST="${COLLECTOR_HOST:?COLLECTOR_HOST not set}"
COLLECTOR_DEST="${COLLECTOR_DEST:-/var/forensics-store}"
COLLECTOR_KEY="${COLLECTOR_KEY:-/etc/redis-forensics/collector_key}"

rc() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning "$@"
}

TS="$(date -u +%Y%m%dT%H%M%SZ)"

# 1. Export volatile artifacts that are only held in memory. This is best-effort:
#    if Redis is momentarily unreachable it must NOT stop us from shipping the
#    already-persisted on-disk evidence (AOF/RDB/logs) below.
mkdir -p "${FORENSICS_DIR}/acl"
if rc PING >/dev/null 2>&1; then
  rc ACL LOG > "${FORENSICS_DIR}/acl/acl-log-${TS}.txt" \
    || echo "warn: ACL LOG export failed" >&2
  # Trigger a fresh RDB snapshot so the on-disk copy reflects current state.
  rc BGSAVE >/dev/null || true
else
  echo "warn: Redis unreachable at ${REDIS_HOST}:${REDIS_PORT}; shipping on-disk artifacts only" >&2
fi

# 2. Push everything to the collector (runs regardless of Redis state).
#    -a preserves timestamps/permissions for chain-of-custody.
SSH_OPTS="ssh -i ${COLLECTOR_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

rsync -a --mkpath -e "$SSH_OPTS" \
  "${FORENSICS_DIR}/" \
  "${COLLECTOR_USER}@${COLLECTOR_HOST}:${COLLECTOR_DEST}/redis-vm/forensics/"

rsync -a --mkpath -e "$SSH_OPTS" \
  "${REDIS_DATA_DIR}/" \
  "${COLLECTOR_USER}@${COLLECTOR_HOST}:${COLLECTOR_DEST}/redis-vm/data/"

rsync -a --mkpath -e "$SSH_OPTS" \
  "${REDIS_LOG_DIR}/" \
  "${COLLECTOR_USER}@${COLLECTOR_HOST}:${COLLECTOR_DEST}/redis-vm/log/"

echo "forensic sync complete @ ${TS}"
