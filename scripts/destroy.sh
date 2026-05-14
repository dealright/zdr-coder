#!/usr/bin/env bash
# Tear down one profile or all.
# Usage:
#   ./scripts/destroy.sh                # all (default)
#   ./scripts/destroy.sh all
#   ./scripts/destroy.sh haiku|sonnet|opus

set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-all}"

[ -f .env ] && { set -a; . ./.env; set +a; }
RUNPOD_API="https://api.runpod.io/graphql"

terminate_pod() {
  local profile="$1"
  local state=".runpod-state.${profile}"
  [ -f "$state" ] || return 0
  local pod_id
  pod_id=$(grep '^POD_ID=' "$state" | cut -d= -f2)
  if [ -n "${pod_id:-}" ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
    echo "→ Terminating $profile pod $pod_id..."
    local resp
    resp=$(curl -sS -X POST "$RUNPOD_API" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$pod_id" '{query:"mutation($id: String!) { podTerminate(input: {podId: $id}) }", variables: {id: $id}}')")
    if [ -n "$(echo "$resp" | jq -r '.data.podTerminate // empty')" ]; then
      echo "  ✓ Terminated"
      rm -f "$state"
    else
      echo "  ⚠ Response: $(echo "$resp" | jq -c .)" >&2
    fi
  fi

  # Bring down WG interface inside the container, then remove conf
  if docker compose ps wg-laptop --status running 2>/dev/null | grep -q wg-laptop; then
    docker compose exec -T wg-laptop wg-quick down "/config/wg_confs/${profile}.conf" >/dev/null 2>&1 || true
  fi
  rm -f "wg/${profile}.conf"
}

case "$PROFILE" in
  all)
    terminate_pod haiku
    terminate_pod sonnet
    terminate_pod opus
    echo "→ Stopping local stack..."
    docker compose down
    echo "  ✓ Local stack stopped"
    ;;
  haiku|sonnet|opus)
    terminate_pod "$PROFILE"
    # If no other profiles remain active, stop local stack
    if ! ls .runpod-state.* >/dev/null 2>&1; then
      echo "→ No remaining profiles; stopping local stack..."
      docker compose down
    fi
    ;;
  *)
    echo "Usage: $0 [all|haiku|sonnet|opus]" >&2
    exit 1
    ;;
esac

echo
echo "Destroy complete."
echo "  .litellm-key and .wg-laptop-private preserved for next deploy."
