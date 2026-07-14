#!/usr/bin/env bash
# gen-pull-key.sh
# Generate a dedicated SSH keypair used ONLY for forensics-vm to PULL evidence
# from redis-vm. The PRIVATE key is deployed to forensics-vm; the PUBLIC key is
# added to a restricted `evidence` user on redis-vm with an rrsync forced command.
# Keys are written to secrets/ (git-ignored). Idempotent: won't clobber.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
KEY_PATH="${SECRETS_DIR}/pull_key"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -f "$KEY_PATH" ]; then
  echo "Pull key already exists at ${KEY_PATH}, leaving it untouched."
  exit 0
fi

ssh-keygen -t ed25519 -N '' -C 'redis-forensics-pull' -f "$KEY_PATH"
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"
echo "Generated pull keypair:"
echo "  Private (-> forensics-vm): ${KEY_PATH}"
echo "  Public  (-> redis-vm)    : ${KEY_PATH}.pub"
