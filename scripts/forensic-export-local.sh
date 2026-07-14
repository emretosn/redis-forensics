#!/usr/bin/env bash
# forensic-export-local.sh  (runs on redis-vm, LOCAL only, no network credentials)
# Consolidates all evidence under a single root (/var/forensics) that the restricted
# `evidence` user can read, so forensics-vm can PULL it. This host holds NO credentials
# to the collector: if redis-vm is compromised it still cannot reach the evidence store.
#
# Exports the in-memory ACL LOG, triggers a fresh RDB snapshot, and mirrors the latest
# on-disk RDB/AOF/log into the evidence root. Run on a systemd timer.
set -euo pipefail
umask 027

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"
FORENSICS_DIR="${FORENSICS_DIR:-/var/forensics}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_LOG_DIR="${REDIS_LOG_DIR:-/var/log/redis}"
EVIDENCE_GROUP="${EVIDENCE_GROUP:-evidence}"

rc() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning "$@"
}

TS="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${FORENSICS_DIR}/acl" "${FORENSICS_DIR}/data" "${FORENSICS_DIR}/log"

# 1. Volatile, in-memory artifacts. Best-effort: a momentary Redis outage must not
#    stop us from mirroring the already-persisted on-disk evidence below.
if rc PING >/dev/null 2>&1; then
  rc ACL LOG > "${FORENSICS_DIR}/acl/acl-log-${TS}.txt" \
    || echo "warn: ACL LOG export failed" >&2
  # Trigger a fresh RDB so the on-disk copy reflects current state.
  rc BGSAVE >/dev/null 2>&1 || true
  sleep 2
else
  echo "warn: Redis unreachable at ${REDIS_HOST}:${REDIS_PORT}; mirroring on-disk artifacts only" >&2
fi

# 2. Mirror the latest on-disk artifacts into the single evidence root.
cp -a "${REDIS_DATA_DIR}/dump.rdb" "${FORENSICS_DIR}/data/" 2>/dev/null || true
[ -e "${REDIS_DATA_DIR}/appendonlydir" ] \
  && cp -a "${REDIS_DATA_DIR}/appendonlydir" "${FORENSICS_DIR}/data/" 2>/dev/null || true
cp -a "${REDIS_LOG_DIR}/redis-server.log" "${FORENSICS_DIR}/log/" 2>/dev/null || true

# 3. Ensure the restricted collector group can read the whole tree (read-only).
chgrp -R "$EVIDENCE_GROUP" "$FORENSICS_DIR" 2>/dev/null || true
chmod -R g+rX "$FORENSICS_DIR" 2>/dev/null || true

echo "local export complete @ ${TS}"
