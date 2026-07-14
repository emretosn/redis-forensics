#!/usr/bin/env bash
# forensic-monitor.sh  (runs on redis-vm)
# Continuous MONITOR capture (Section VI: continuously capture & store MONITOR output).
# Runs as a long-lived systemd service; MONITOR streams every command issued to Redis.
#
# Seal-and-rotate model: capture always writes to a single 'monitor.current' file.
# On each (re)start this script first SEALS any leftover current file into a final,
# timestamped 'monitor-<ts>.log' (which the collector then pulls once and freezes).
# A systemd timer restarts this service periodically to roll a new sealed segment,
# so the collector only ever ingests complete, immutable capture files.
set -euo pipefail
umask 027

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"
FORENSICS_DIR="${FORENSICS_DIR:-/var/forensics}"

OUT_DIR="${FORENSICS_DIR}/monitor"
mkdir -p "$OUT_DIR"
CUR="${OUT_DIR}/monitor.current"

# Seal a leftover capture from a previous run so each sealed file is complete.
if [ -f "$CUR" ]; then
  mv "$CUR" "${OUT_DIR}/monitor-$(date -u +%Y%m%dT%H%M%SZ).log"
fi

echo "# MONITOR capture started $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CUR"

# --no-auth-warning keeps the password out of stderr noise.
exec redis-cli \
  -h "$REDIS_HOST" -p "$REDIS_PORT" \
  --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning \
  MONITOR >> "$CUR"
