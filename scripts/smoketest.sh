#!/usr/bin/env bash
# Smoke-test the full deployment path:
#   Cline → LiteLLM (local) → Tailscale → vLLM (remote GPU)
# Reads .env, posts a chat completion, reports PASS or FAIL with a remediation hint.
# Idempotent, no state changes.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "FAIL: .env missing. Run scripts/preflight.sh first." >&2
  exit 1
fi

set -a
. ./.env
set +a

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "FAIL: LITELLM_MASTER_KEY not set in .env" >&2
  exit 1
fi

ENDPOINT="${LITELLM_ENDPOINT:-http://localhost:4000/v1/chat/completions}"
MODEL_ALIAS="${MODEL_ALIAS:-heavy}"

echo "→ POST ${ENDPOINT}"
echo "→ model alias: ${MODEL_ALIAS}"
echo "→ prompt: \"Reply with the word PONG only.\""
echo

RESP=$(curl -sS --max-time 90 \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word PONG only.\"}]}" \
  "${ENDPOINT}" 2>&1)
CURL_RC=$?

if [ "${CURL_RC}" -ne 0 ]; then
  echo "FAIL: curl returned ${CURL_RC}" >&2
  echo "  → Is LiteLLM running?  docker compose ps" >&2
  echo "  → LiteLLM logs:        docker compose logs --tail=20 litellm" >&2
  exit 1
fi

# Extract content / error. jq preferred, fall back to grep.
if command -v jq >/dev/null 2>&1; then
  CONTENT=$(echo "${RESP}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  ERROR=$(echo "${RESP}" | jq -r '.error.message // empty' 2>/dev/null)
else
  CONTENT=$(echo "${RESP}" | grep -oE '"content":"[^"]*"' | head -1 | sed 's/^"content":"//;s/"$//')
  ERROR=$(echo "${RESP}" | grep -oE '"message":"[^"]*"' | head -1 | sed 's/^"message":"//;s/"$//')
fi

if [ -n "${ERROR}" ]; then
  echo "FAIL: API returned error: ${ERROR}" >&2
  shopt -s nocasematch
  case "${ERROR}" in
    *"connection refused"*|*"could not connect"*|*"no route to host"*)
      echo "  → vLLM unreachable. From this machine with Tailscale running:" >&2
      echo "      docker compose logs wg-laptop | tail -20    # check WG handshake" >&2
      echo "      docker compose exec wg-laptop wg show wg0   # peer should show latest handshake" >&2
      echo "      docker compose exec wg-laptop curl http://10.99.0.2:8000/v1/models" >&2
      ;;
    *"unauthorized"*|*"invalid"*"api"*|*"invalid api key"*)
      echo "  → LiteLLM master key mismatch. Verify .env matches what Cline sends." >&2
      ;;
    *"not ready"*|*"loading"*|*"starting"*)
      echo "  → vLLM is still warming up. Wait 1–2 min and re-run." >&2
      ;;
    *)
      echo "  → See LiteLLM logs: docker compose logs --tail=40 litellm" >&2
      ;;
  esac
  shopt -u nocasematch
  exit 1
fi

if [ -z "${CONTENT}" ]; then
  echo "FAIL: empty content in response." >&2
  echo "  → Raw (first 500 chars):" >&2
  echo "${RESP}" | head -c 500 >&2
  echo >&2
  exit 1
fi

if echo "${CONTENT}" | grep -qi "PONG"; then
  echo "PASS: vLLM responded \"${CONTENT}\""
  exit 0
else
  echo "FAIL: model did not return PONG. Got: \"${CONTENT}\""
  echo "  → Path works but model ignored the instruction. Try a longer prompt or check tokenizer." >&2
  exit 1
fi
