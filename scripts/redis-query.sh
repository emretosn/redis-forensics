#!/usr/bin/env bash
# redis-query.sh — convenience wrapper to query redis-vm as a chosen ACL role.
# Usage: redis-query.sh <reader|writer|admin> <redis command...>
#   e.g. redis-query.sh reader GET key1
#        redis-query.sh writer SET key9 hello
#        redis-query.sh reader FLUSHALL      # should be denied -> ACL LOG entry
set -euo pipefail

ENV_FILE="${CLIENT_ENV:-/etc/redis-forensics/client.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

ROLE="${1:-reader}"; shift || true

case "$ROLE" in
  reader) USER="$READER_USER"; PASS="$READER_PASS" ;;
  writer) USER="$WRITER_USER"; PASS="$WRITER_PASS" ;;
  admin)  USER="$ADMIN_USER";  PASS="$ADMIN_PASS"  ;;
  *) echo "unknown role: $ROLE (use reader|writer|admin)" >&2; exit 2 ;;
esac

exec redis-cli \
  -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" \
  --user "$USER" --pass "$PASS" --no-auth-warning "$@"
