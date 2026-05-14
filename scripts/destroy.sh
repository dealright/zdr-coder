#!/usr/bin/env bash
# Tear down: stop RunPod pod (billing stops within ~1 min) + stop local LiteLLM.
# Idempotent: safe to re-run.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

RUNPOD_API="https://api.runpod.io/graphql"

# ── Stop RunPod pod if state file exists ─────────────────
if [ -f .runpod-state ]; then
  POD_ID=$(grep '^POD_ID=' .runpod-state | cut -d= -f2)
  if [ -n "${POD_ID:-}" ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
    echo "→ Stopping RunPod pod $POD_ID..."
    RESP=$(curl -sS -X POST "$RUNPOD_API" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$POD_ID" '{query:"mutation($id: String!) { podTerminate(input: {podId: $id}) }", variables: {id: $id}}')")
    OK=$(echo "$RESP" | jq -r '.data.podTerminate // empty')
    if [ -n "$OK" ]; then
      echo "  ✓ Pod terminated (billing stops within ~1 min)"
      rm -f .runpod-state
    else
      echo "  ⚠ Termination response: $(echo "$RESP" | jq -c .)" >&2
    fi
  else
    echo "→ No cached pod ID or RUNPOD_API_KEY; skipping remote teardown"
  fi
else
  echo "→ No .runpod-state file; nothing to tear down remotely"
fi

# ── Stop local LiteLLM ───────────────────────────────────
echo "→ Stopping local LiteLLM..."
docker compose down
echo "  ✓ Local stopped"

echo
echo "Destroy complete."
