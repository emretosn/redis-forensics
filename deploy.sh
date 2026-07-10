#!/usr/bin/env bash
# deploy.sh
# Stage secrets/keys, then deploy the Redis forensic-readiness lab to Azure.
#
# Prereqs: az CLI logged in (az login). Existing SSH pubkey at ~/.ssh/id_ed25519.pub.
#
# Environment overrides (all optional):
#   RG_NAME              resource group name        (default: rg-redis-forensics)
#   LOCATION             azure region               (default: westeurope)
#   ADMIN_PUBKEY_PATH    admin SSH public key       (default: ~/.ssh/id_ed25519.pub)
#   ADMIN_SOURCE_ADDRESS your SSH source IP/CIDR    (default: auto-detected)
#   REDIS_READER_PASS / REDIS_WRITER_PASS / REDIS_ADMIN_PASS (default: generated)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

RG_NAME="${RG_NAME:-rg-redis-forensics}"
LOCATION="${LOCATION:-westeurope}"
ADMIN_PUBKEY_PATH="${ADMIN_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
SECRETS_DIR="${REPO_ROOT}/secrets"

mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"

# --- 1. Stage admin SSH public key ------------------------------------------
if [ ! -f "$ADMIN_PUBKEY_PATH" ]; then
  echo "ERROR: admin SSH public key not found at $ADMIN_PUBKEY_PATH" >&2
  exit 1
fi
cp "$ADMIN_PUBKEY_PATH" "${SECRETS_DIR}/admin_key.pub"

# --- 2. Ensure collector keypair exists -------------------------------------
"${REPO_ROOT}/scripts/gen-collector-key.sh"

# --- 3. Determine SSH source address ----------------------------------------
# Your egress IP can drift within a NAT pool. To keep SSH working across a test
# deployment, the auto-detected IP is widened to its containing /23 by default.
# Override ADMIN_SOURCE_ADDRESS to pin an exact value (e.g. a /32 for production),
# or set ADMIN_SOURCE_PREFIX_BITS to change the widening (e.g. 32 = no widening).
if [ -z "${ADMIN_SOURCE_ADDRESS:-}" ]; then
  PREFIX_BITS="${ADMIN_SOURCE_PREFIX_BITS:-23}"
  DETECTED_IP="$(curl -fsSL https://api.ipify.org)"
  if [ "$PREFIX_BITS" -eq 23 ]; then
    IFS=. read -r o1 o2 o3 _o4 <<< "$DETECTED_IP"
    ADMIN_SOURCE_ADDRESS="${o1}.${o2}.$(( o3 & 0xFE )).0/23"
  else
    ADMIN_SOURCE_ADDRESS="${DETECTED_IP}/${PREFIX_BITS}"
  fi
  echo "auto-detected IP ${DETECTED_IP} -> ADMIN_SOURCE_ADDRESS=${ADMIN_SOURCE_ADDRESS}"
fi
export ADMIN_SOURCE_ADDRESS

# --- 4. Generate Redis ACL passwords if not provided ------------------------
gen_pass() { openssl rand -hex 16; }
export REDIS_READER_PASS="${REDIS_READER_PASS:-$(gen_pass)}"
export REDIS_WRITER_PASS="${REDIS_WRITER_PASS:-$(gen_pass)}"
export REDIS_ADMIN_PASS="${REDIS_ADMIN_PASS:-$(gen_pass)}"

# Persist generated passwords for later reference (git-ignored).
cat > "${SECRETS_DIR}/passwords.env" <<EOF
REDIS_READER_PASS=${REDIS_READER_PASS}
REDIS_WRITER_PASS=${REDIS_WRITER_PASS}
REDIS_ADMIN_PASS=${REDIS_ADMIN_PASS}
EOF
chmod 600 "${SECRETS_DIR}/passwords.env"
echo "Redis ACL passwords written to ${SECRETS_DIR}/passwords.env"

# --- 5. Deploy --------------------------------------------------------------
echo "Creating resource group ${RG_NAME} in ${LOCATION}..."
az group create --name "$RG_NAME" --location "$LOCATION" --output none

echo "Deploying infrastructure..."
az deployment group create \
  --resource-group "$RG_NAME" \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters location="$LOCATION" \
  --output table

echo "Deployment complete. See outputs above for SSH commands and IPs."
