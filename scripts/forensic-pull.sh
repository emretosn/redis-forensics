#!/usr/bin/env bash
# forensic-pull.sh  (runs on forensics-vm, as root, on a systemd timer)
# PULL model: the collector initiates every transfer over SSH using a dedicated
# read-only key. redis-vm holds no credentials to this host, so a compromise of the
# Redis network cannot reach or alter the evidence stored here.
#
# The evidence store is WRITE-ONCE / immutable:
#   - monitor/config/acl : unique filenames, copied once (--ignore-existing), chattr +i.
#   - data/log           : per-pull timestamped snapshot dirs, chattr +i, deduped by
#                          sha256 so unchanged RDB/AOF/log are not re-stored.
#   - manifest/          : sha256 manifest per pull cycle (immutable) for integrity.
# Immutability (+i) means freeing space is a deliberate, privileged action; evidence
# is never silently overwritten or auto-deleted.
set -euo pipefail

ENV_FILE="${PULL_ENV:-/etc/redis-forensics/pull.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

SOURCE_USER="${SOURCE_USER:-evidence}"
SOURCE_HOST="${SOURCE_HOST:?SOURCE_HOST not set}"
PULL_KEY="${PULL_KEY:-/etc/redis-forensics/pull_key}"
STORE="${STORE_DIR:-/var/forensics-store/redis-vm}"
STATE="${STATE_DIR:-/var/lib/forensic-pull}"

SSH_OPTS="ssh -i ${PULL_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "${STORE}"/{monitor,config,acl,data,log,manifest} "$STATE"

# --- 1. Append-only, unique-name artifacts: copy once, then freeze. -----------
# The rrsync forced command on redis-vm roots all paths at /var/forensics, so the
# subdir names below are relative to that evidence root.
for sub in monitor config acl; do
  exclude=()
  [ "$sub" = monitor ] && exclude=(--exclude 'monitor.current')
  if rsync -a --ignore-existing "${exclude[@]}" -e "$SSH_OPTS" \
      "${SOURCE_USER}@${SOURCE_HOST}:${sub}/" "${STORE}/${sub}/"; then
    find "${STORE}/${sub}" -type f -exec chattr +i {} + 2>/dev/null || true
  else
    echo "warn: pull of ${sub}/ failed" >&2
  fi
done

# --- 2. Mutable-source artifacts (rdb/aof/log): versioned immutable snapshots. -
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

snapshot() {
  local sub="$1"                       # data | log
  local stagedir="${STAGE}/${sub}"
  rsync -a -e "$SSH_OPTS" \
    "${SOURCE_USER}@${SOURCE_HOST}:${sub}/" "${stagedir}/" 2>/dev/null || {
      echo "warn: pull of ${sub}/ failed" >&2; return 0; }
  [ -n "$(ls -A "$stagedir" 2>/dev/null || true)" ] || return 0
  # Content hash of the whole subtree; skip if identical to the last snapshot.
  local h last
  h="$(find "$stagedir" -type f -exec sha256sum {} + | sort | sha256sum | awk '{print $1}')"
  last="$(cat "${STATE}/last-${sub}-hash" 2>/dev/null || true)"
  if [ "$h" = "$last" ]; then
    return 0
  fi
  local dest="${STORE}/${sub}/${TS}"
  mkdir -p "$dest"
  cp -a "${stagedir}/." "$dest/"
  find "$dest" -type f -exec chattr +i {} + 2>/dev/null || true
  echo "$h" > "${STATE}/last-${sub}-hash"
}

snapshot data
snapshot log

# --- 3. Integrity manifest for this pull cycle (immutable). -------------------
MAN="${STORE}/manifest/manifest-${TS}.sha256"
( cd "$STORE" && find monitor config acl data log -type f -exec sha256sum {} + ) \
  > "$MAN" 2>/dev/null || true
chattr +i "$MAN" 2>/dev/null || true

echo "forensic pull complete @ ${TS}"
