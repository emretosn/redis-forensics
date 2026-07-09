#!/usr/bin/env bash
# forensic-config-snap.sh
# Periodic CONFIG GET snapshot (Section VI: schedule periodic CONFIG GET snapshots).
# Run on a systemd timer; writes a timestamped dump of the full runtime config so
# unauthorized configuration changes can be detected by diffing snapshots.
set -euo pipefail

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"
FORENSICS_DIR="${FORENSICS_DIR:-/var/forensics}"

OUT_DIR="${FORENSICS_DIR}/config"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/config-${TS}.txt"

{
  echo "# CONFIG GET * snapshot @ ${TS}"
  redis-cli \
    -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning \
    CONFIG GET '*'
} > "$OUT_FILE"

echo "wrote ${OUT_FILE}"
