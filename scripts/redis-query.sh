#!/usr/bin/env bash
# redis-query.sh — query redis-vm as a chosen Redis ACL user.
#
# Option A model: NO passwords are stored on this VM. You supply your own
# credential at runtime. Two ways to authenticate:
#
#   1. Per-command prompt (default): you are asked for the password each call.
#        redis-query.sh reader GET key9
#
#   2. Per-session login (no re-typing): export your password once for the
#      current shell (read -s keeps it out of shell history), then run commands:
#        read -rs REDIS_PASS && export REDIS_PASS      # type your password
#        redis-query.sh reader GET key9
#        redis-query.sh reader SMEMBERS set1
#        unset REDIS_PASS                              # "log out" of the session
#
# Usage: redis-query.sh <redis-username> <redis command...>
#   e.g. redis-query.sh reader GET key1
#        redis-query.sh writer SET key9 hello
#        redis-query.sh reader FLUSHALL     # denied for reader -> ACL LOG entry
set -euo pipefail

ENV_FILE="${CLIENT_ENV:-/etc/redis-forensics/client.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

if [ "$#" -lt 1 ]; then
  echo "usage: redis-query.sh <redis-username> <redis command...>" >&2
  exit 2
fi
USER="$1"; shift

if [ -n "${REDIS_PASS:-}" ]; then
  # Session login: password provided via environment (never written to disk).
  exec redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$USER" --pass "$REDIS_PASS" --no-auth-warning "$@"
else
  # No stored/exported password: prompt securely for this single command.
  exec redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
    --user "$USER" --askpass "$@"
fi
