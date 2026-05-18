#!/usr/bin/env bash
# Tear down one profile or all.
# Usage: ./scripts/destroy.sh [haiku|sonnet|opus|haiku-serverless|all]
# Default: all.

set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-all}"

[ -f .env ] && { set -a; . ./.env; set +a; }
RUNPOD_API="https://api.runpod.io/graphql"

gql() {
  curl -sS -X POST "$RUNPOD_API" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query:$q,variables:$v}')"
}

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
      gql 'mutation($id: String!) { podTerminate(input: {podId: $id}) }' "{\"id\":\"$pod_id\"}" >/dev/null
      echo "  ✓ Terminated"
      rm -f "$state"
    fi
  fi
  if [ -f .env-runtime ]; then
    grep -v "^${profile_upper}_API_" .env-runtime > .env-runtime.tmp || true
    mv .env-runtime.tmp .env-runtime
  fi
}

terminate_serverless() {
  local route="$1"
  local state=".runpod-state.${route}"
  local route_upper
  route_upper=$(echo "$route" | tr '[:lower:]-' '[:upper:]_')

  if [ -f "$state" ] && [ -n "${RUNPOD_API_KEY:-}" ]; then
    local endpoint_id template_id
    endpoint_id=$(grep '^ENDPOINT_ID=' "$state" | cut -d= -f2)
    template_id=$(grep '^TEMPLATE_ID=' "$state" | cut -d= -f2)

    if [ -n "${endpoint_id:-}" ]; then
      echo "→ Deleting $route endpoint $endpoint_id..."
      # deleteEndpoint works even with throttled/queued workers — no need to
      # scale to zero first. (saveEndpoint updates require gpuIds anyway.)
      gql 'mutation($id:String!){ deleteEndpoint(id:$id) }' "{\"id\":\"$endpoint_id\"}" >/dev/null
      echo "  ✓ Endpoint deleted"
    fi
    if [ -n "${template_id:-}" ]; then
      gql "mutation { deleteTemplate(templateName: \"zdr-coder-${route}\") }" '{}' >/dev/null
      echo "  ✓ Template deleted"
    fi
    rm -f "$state"
  fi
  if [ -f .env-runtime ]; then
    grep -v "^${route_upper}_API_" .env-runtime > .env-runtime.tmp || true
    mv .env-runtime.tmp .env-runtime
  fi
}

case "$PROFILE" in
  all)
    terminate_pod haiku
    terminate_pod sonnet
    terminate_pod opus
    terminate_serverless haiku-serverless
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
  haiku-serverless)
    terminate_serverless "$PROFILE"
    if [ -f .env-runtime ] && [ -s .env-runtime ]; then
      docker compose up -d --force-recreate litellm >/dev/null 2>&1 || true
      echo "  ✓ LiteLLM reloaded with remaining profiles"
    else
      docker compose down
      echo "  ✓ No profiles left — LiteLLM stopped"
    fi
    ;;
  *)
    echo "Usage: $0 [all|haiku|sonnet|opus|haiku-serverless]" >&2
    exit 1
    ;;
esac

echo
echo "Destroy complete. .litellm-key + .vllm-key.* preserved for next deploy."
