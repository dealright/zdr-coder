#!/usr/bin/env bash
# Interactively write ~/.cloudflare/r2.credentials and ~/.cloudflare/accountid
# for SkyPilot's Cloudflare R2 integration.
#
# Usage: ./scripts/setup-r2.sh
#
# Get values: https://dash.cloudflare.com → R2 Object Storage → Manage R2 API Tokens
#   - Account ID: shown in R2 page sidebar (also in URL after dash.cloudflare.com/)
#   - Access Key ID + Secret Access Key: from "Create API Token" with Object R+W permission
#
# R2 is used as the bucket backing for pre-staged opus-class model weights
# (e.g., Kimi K2.6 554 GB). Free egress + cheap storage make it ideal for
# repeated mounting from GPU pods on RunPod/Verda/etc.

set -euo pipefail

CFG_DIR="$HOME/.cloudflare"
CREDS_FILE="$CFG_DIR/r2.credentials"
ACCID_FILE="$CFG_DIR/accountid"

if [[ -f "$CREDS_FILE" && -f "$ACCID_FILE" ]]; then
  echo "⚠️  Cloudflare R2 already configured. Overwrite? [y/N]"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$CFG_DIR"

echo "Paste your Cloudflare Account ID (32-char hex, find at dash.cloudflare.com → R2):"
read -r ACCOUNT_ID

echo "Paste your R2 Access Key ID (from Manage R2 API Tokens → Create):"
read -r ACCESS_KEY_ID

echo "Paste your R2 Secret Access Key (hidden, one-time view — get it now):"
read -rs SECRET_ACCESS_KEY
echo

# Write account ID
echo -n "$ACCOUNT_ID" > "$ACCID_FILE"
chmod 600 "$ACCID_FILE"
echo "✅ Wrote $ACCID_FILE"

# Write S3-compatible credentials file
cat > "$CREDS_FILE" <<EOF
[r2]
aws_access_key_id = $ACCESS_KEY_ID
aws_secret_access_key = $SECRET_ACCESS_KEY
EOF
chmod 600 "$CREDS_FILE"
echo "✅ Wrote $CREDS_FILE (0600)"

# Verify SkyPilot picks it up
if command -v sky >/dev/null 2>&1; then
  SKY=sky
elif [[ -x .venv-sky/bin/sky ]]; then
  SKY=.venv-sky/bin/sky
else
  echo "ℹ️  SkyPilot CLI not found. After setup, run: sky check cloudflare"
  exit 0
fi

echo
echo "Running sky check cloudflare..."
"$SKY" check cloudflare 2>&1 | grep -E "Cloudflare|enabled|disabled|Reason" || true
