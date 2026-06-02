#!/usr/bin/env bash
# Launch Aider against the local LiteLLM proxy.
#
# Usage:
#   ./scripts/aider.sh                          # default: sonnet-api
#   ZDR_MODEL=haiku-api ./scripts/aider.sh      # cheap haiku-tier model
#   ZDR_MODEL=sonnet-vast ./scripts/aider.sh    # self-hosted route (requires deploy-vast.sh sonnet running)
#   ./scripts/aider.sh some/file.py             # extra args forwarded to aider
#
# Slash commands inside Aider: /add, /run, /commit, /undo, /help

set -euo pipefail
cd "$(dirname "$0")/.."

command -v aider >/dev/null 2>&1 || {
  echo "FAIL: aider not installed. Run: ./scripts/aider-up.sh" >&2
  exit 1
}

[ -f .litellm-key ] || {
  echo "FAIL: .litellm-key missing. Bring up a deploy first, e.g.:" >&2
  echo "  ./scripts/api-up.sh                    (Groq API mode)" >&2
  echo "  ./scripts/deploy-vast.sh sonnet        (self-hosted)" >&2
  exit 1
}

MODEL="${ZDR_MODEL:-sonnet-api}"
BASE="${LITELLM_BASE_URL:-http://localhost:4000/v1}"
KEY=$(cat .litellm-key)

# Verify LiteLLM is reachable before launching aider — saves a confusing
# "OpenAI Connection error" mid-prompt.
HTTP=$(curl -sS -m 3 -o /dev/null -w "%{http_code}" "$BASE/models" \
  -H "Authorization: Bearer $KEY" 2>/dev/null || echo 000)
if [ "$HTTP" != "200" ]; then
  echo "FAIL: LiteLLM at $BASE returned HTTP $HTTP." >&2
  echo "  Is the proxy running?  docker compose ps" >&2
  exit 1
fi

# Aider reads OPENAI_API_BASE / OPENAI_API_KEY env vars; pass model + format
# on the command line. --edit-format diff is the sweet spot for 70B-class
# open models (whole-file is too verbose, udiff is too strict).
export OPENAI_API_BASE="$BASE"
export OPENAI_API_KEY="$KEY"

exec aider \
  --model "openai/$MODEL" \
  --edit-format diff \
  --no-show-model-warnings \
  --no-auto-commits \
  "$@"
