#!/usr/bin/env bash
# Interactively write ~/.verda/config.json for SkyPilot.
# Verda (formerly DataCrunch) credentials are stored in a JSON file, not env vars.
#
# Usage: ./scripts/setup-verda.sh
#
# Get credentials: https://console.verda.com → Dashboard → your project → Keys

set -euo pipefail

CFG_DIR="$HOME/.verda"
CFG_FILE="$CFG_DIR/config.json"

if [[ -f "$CFG_FILE" ]]; then
  echo "⚠️  ~/.verda/config.json already exists. Overwrite? [y/N]"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$CFG_DIR"

echo "Paste your Verda Client ID (from https://console.verda.com → Dashboard → Keys):"
read -r CLIENT_ID

echo "Paste your Verda Client Secret (one-time view — get it now before navigating away):"
read -rs CLIENT_SECRET
echo

read -rp "Default region [FIN-03]: " REGION
REGION="${REGION:-FIN-03}"

cat > "$CFG_FILE" <<EOF
{
  "client_id": "$CLIENT_ID",
  "client_secret": "$CLIENT_SECRET",
  "base_url": "https://api.verda.com/v1",
  "default_region": "$REGION"
}
EOF

chmod 600 "$CFG_FILE"
echo "✅ Wrote $CFG_FILE (0600)"
echo "Now run: sky check verda"
