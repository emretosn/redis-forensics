#!/usr/bin/env bash
# seed-data.sh
# Seed a few simple key:value pairs so the lab has baseline data to query.
set -euo pipefail

ENV_FILE="${FORENSICS_ENV:-/etc/redis-forensics/forensics.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
ADMIN_USER="${ADMIN_USER:-admin}"

rc() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$ADMIN_USER" --pass "$ADMIN_PASS" --no-auth-warning "$@"
}

rc SET key1 value1
rc SET key2 value2
rc SET key3 value3
rc SADD set1 a b c

echo "seed complete: $(rc DBSIZE) keys"
