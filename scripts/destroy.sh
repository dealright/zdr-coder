#!/usr/bin/env bash
# Tear down one profile or all.
# Usage: ./scripts/destroy.sh [haiku|sonnet|opus|all]
# Default: all.

set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-all}"

[ -f .env ] && { set -a; . ./.env; set +a; }
RUNPOD_API="https://api.runpod.io/graphql"

terminate_pod() {
  local profile="$1"
  local state=".runpod-state.${profile}"
  local profile_upper
  profile_upper=$(echo "$profile" | tr '[:lower:]' '[:upper:]')

  if [ -f "$state" ]; then
    local pod_id
    pod_id=$(grep '^POD_ID=' "$state" | cut -d= -f2)
    if [ -n "${pod_id:-}" ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
      echo "→ Terminating $profile pod $pod_id..."
      curl -sS -X POST "$RUNPOD_API" \
        -H "Authorization: Bearer $RUNPOD_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg id "$pod_id" '{query:"mutation($id: String!) { podTerminate(input: {podId: $id}) }", variables: {id: $id}}')" >/dev/null
      echo "  ✓ Terminated"
      rm -f "$state"
    fi
  fi
  # Strip this profile's entries from .env-runtime
  if [ -f .env-runtime ]; then
    grep -v "^${profile_upper}_API_" .env-runtime > .env-runtime.tmp || true
    mv .env-runtime.tmp .env-runtime
  fi
}

case "$PROFILE" in
  all)
    terminate_pod haiku
    terminate_pod sonnet
    terminate_pod opus
    docker compose down
    echo "  ✓ Local LiteLLM stopped"
    ;;
  haiku|sonnet|opus)
    terminate_pod "$PROFILE"
    if [ -f .env-runtime ] && [ -s .env-runtime ]; then
      docker compose up -d --force-recreate litellm >/dev/null 2>&1 || true
      echo "  ✓ LiteLLM reloaded with remaining profiles"
    else
      docker compose down
      echo "  ✓ No profiles left — LiteLLM stopped"
    fi
    ;;
  *)
    echo "Usage: $0 [all|haiku|sonnet|opus]" >&2
    exit 1
    ;;
esac

echo
echo "Destroy complete. .litellm-key + .vllm-key.* preserved for next deploy."
