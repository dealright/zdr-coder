#!/usr/bin/env bash
# Smoke-test one profile end-to-end:
#   Cline → LiteLLM (local) → WireGuard → vLLM (remote GPU)
# Usage:
#   ./scripts/smoketest.sh              # default: sonnet
#   ./scripts/smoketest.sh haiku|sonnet|opus

set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-sonnet}"
case "$PROFILE" in haiku|sonnet|opus) ;; *)
  echo "FAIL: unknown profile '$PROFILE'. Use: haiku | sonnet | opus" >&2; exit 1 ;;
esac

[ -f .env ] || { echo "FAIL: .env missing. Run scripts/preflight.sh first." >&2; exit 1; }
set -a
. ./.env
set +a

LITELLM_MASTER_KEY=$(cat .litellm-key 2>/dev/null) || \
  { echo "FAIL: .litellm-key not found. Run deploy.sh first." >&2; exit 1; }

ENDPOINT="${LITELLM_ENDPOINT:-http://localhost:4000/v1/chat/completions}"

echo "→ POST ${ENDPOINT}"
echo "→ model: ${PROFILE}"
echo "→ prompt: \"Reply with the word PONG only.\""
echo

RESP=$(curl -sS --max-time 90 \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${PROFILE}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word PONG only.\"}]}" \
  "${ENDPOINT}" 2>&1)
CURL_RC=$?

if [ "${CURL_RC}" -ne 0 ]; then
  echo "FAIL: curl returned ${CURL_RC}" >&2
  echo "  → Is LiteLLM running?  docker compose ps" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  CONTENT=$(echo "${RESP}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  ERROR=$(echo "${RESP}"   | jq -r '.error.message // empty' 2>/dev/null)
else
  CONTENT=$(echo "${RESP}" | grep -oE '"content":"[^"]*"' | head -1 | sed 's/^"content":"//;s/"$//')
  ERROR=$(echo "${RESP}"   | grep -oE '"message":"[^"]*"' | head -1 | sed 's/^"message":"//;s/"$//')
fi

if [ -n "${ERROR}" ]; then
  echo "FAIL [${PROFILE}]: ${ERROR}" >&2
  shopt -s nocasematch
  case "${ERROR}" in
    *"connection refused"*|*"could not connect"*|*"no route to host"*)
      echo "  → vLLM/WG unreachable for $PROFILE. Inside the WG container:" >&2
      echo "      docker compose exec wg-laptop wg show $PROFILE" >&2
      echo "      (look for 'latest handshake'; if blank, peer isn't connecting)" >&2
      ;;
    *"unauthorized"*|*"invalid"*"api"*)
      echo "  → LiteLLM master key mismatch. Check .litellm-key vs Cline config." >&2 ;;
    *"not ready"*|*"loading"*|*"starting"*)
      echo "  → vLLM still warming up. Wait 1–2 min and re-run." >&2 ;;
  esac
  shopt -u nocasematch
  exit 1
fi

if [ -z "${CONTENT}" ]; then
  echo "FAIL [${PROFILE}]: empty content. Raw:" >&2
  echo "${RESP}" | head -c 500 >&2; echo >&2
  exit 1
fi

if echo "${CONTENT}" | grep -qi "PONG"; then
  echo "PASS [${PROFILE}]: vLLM responded \"${CONTENT}\""
  exit 0
else
  echo "FAIL [${PROFILE}]: model did not return PONG. Got: \"${CONTENT}\""
  exit 1
fi
