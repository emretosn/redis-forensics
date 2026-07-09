#!/usr/bin/env bash
# gen-collector-key.sh
# Generate a dedicated SSH keypair used only for redis-vm to forensics-vm evidence
# transfer. Keys are written to secrets/ (git-ignored). Idempotent: won't clobber.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
KEY_PATH="${SECRETS_DIR}/collector_key"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -f "$KEY_PATH" ]; then
  echo "Collector key already exists at ${KEY_PATH}, leaving it untouched."
  exit 0
fi

ssh-keygen -t ed25519 -N '' -C 'redis-forensics-collector' -f "$KEY_PATH"
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"
echo "Generated collector keypair:"
echo "  Private: ${KEY_PATH}"
echo "  Public : ${KEY_PATH}.pub"
