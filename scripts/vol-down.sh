#!/usr/bin/env bash
# Tear down a Vast.ai data volume created by vol-up.sh.
# Stops the per-second storage billing entirely.
#
# Usage:  ./scripts/vol-down.sh <profile>

set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-}"
case "$PROFILE" in haiku|sonnet|opus) ;; *)
  echo "Usage: $0 [haiku|sonnet|opus]" >&2; exit 1 ;;
esac

ROUTE="${PROFILE}-vast"
VOL_STATE=".runpod-state.${ROUTE}-volume"
[ -f "$VOL_STATE" ] || { echo "No volume state file $VOL_STATE — nothing to do." >&2; exit 0; }

[ -f .env ] && { set -a; . ./.env; set +a; }
: "${VAST_API_KEY:?VAST_API_KEY required}"

VOL_ID=$(grep '^VOLUME_ID=' "$VOL_STATE" | cut -d= -f2)
POP_ID=$(grep '^POPULATE_INSTANCE=' "$VOL_STATE" | cut -d= -f2 || true)

if [ -n "$POP_ID" ]; then
  echo "→ Terminating populate pod $POP_ID (if still running)..."
  curl -sS -X DELETE "https://console.vast.ai/api/v0/instances/${POP_ID}/" \
    -H "Authorization: Bearer $VAST_API_KEY" >/dev/null
fi

if [ -n "$VOL_ID" ]; then
  echo "→ Deleting volume $VOL_ID..."
  curl -sS -X DELETE "https://console.vast.ai/api/v0/volumes/${VOL_ID}/" \
    -H "Authorization: Bearer $VAST_API_KEY"; echo
fi

rm -f "$VOL_STATE"
echo "✓ Volume teardown complete. Storage billing stopped."
