#!/usr/bin/env bash
# forensic-monitor.sh
# Continuous MONITOR capture (Section VI: continuously capture & store MONITOR output).
# Runs as a long-lived systemd service; MONITOR streams every command issued to Redis.
set -euo pipefail

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"
FORENSICS_DIR="${FORENSICS_DIR:-/var/forensics}"

OUT_DIR="${FORENSICS_DIR}/monitor"
mkdir -p "$OUT_DIR"
OUT_FILE="${OUT_DIR}/monitor-$(date -u +%Y%m%dT%H%M%SZ).log"

echo "# MONITOR capture started $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT_FILE"

# --no-auth-warning keeps the password out of stderr noise.
exec redis-cli \
  -h "$REDIS_HOST" -p "$REDIS_PORT" \
  --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning \
  MONITOR >> "$OUT_FILE"
