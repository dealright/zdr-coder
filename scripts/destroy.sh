#!/usr/bin/env bash
# Tear down: terminate RunPod pod (billing stops in ~1 min) + stop local stack.
# Keeps .litellm-key for next deploy. Removes ephemeral mesh state.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

RUNPOD_API="https://api.runpod.io/graphql"

# ── Terminate RunPod pod ─────────────────────────────────
if [ -f .runpod-state ]; then
  POD_ID=$(grep '^POD_ID=' .runpod-state | cut -d= -f2)
  if [ -n "${POD_ID:-}" ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
    echo "→ Terminating RunPod pod $POD_ID..."
    RESP=$(curl -sS -X POST "$RUNPOD_API" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$POD_ID" '{query:"mutation($id: String!) { podTerminate(input: {podId: $id}) }", variables: {id: $id}}')")
    if [ -n "$(echo "$RESP" | jq -r '.data.podTerminate // empty')" ]; then
      echo "  ✓ Terminated (billing stops in ~1 min)"
      rm -f .runpod-state
    else
      echo "  ⚠ Termination response: $(echo "$RESP" | jq -c .)" >&2
    fi
  fi
fi

# ── Stop local stack (headscale + cloudflared + litellm + ts-litellm) ──
echo "→ Stopping local stack..."
docker compose down
echo "  ✓ Local stack stopped"

echo
echo "Destroy complete."
echo "  .litellm-key preserved for next deploy (same Cline API key)."
echo "  Headscale mesh state in 'headscale-state' volume preserved unless you run: docker compose down -v"
