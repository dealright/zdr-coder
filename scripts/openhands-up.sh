#!/usr/bin/env bash
# Bring up OpenHands as a browser-based AI coding agent pointed at our local
# LiteLLM proxy. For users who'd rather click around in a web UI than type in
# a terminal — runs at http://localhost:3000 once started.
#
# Requires: ./scripts/api-up.sh already run (so LiteLLM is on :4000), Docker
# Desktop running, the workspace folder accessible.
#
# Usage:
#   ./scripts/openhands-up.sh                       # default: sonnet-api, workspace = parent dir
#   ZDR_MODEL=opus-vast ./scripts/openhands-up.sh   # use a different tier
#   WORKSPACE=/path/to/project ./scripts/openhands-up.sh
#
# Stop with: ./scripts/openhands-down.sh

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .litellm-key ] || {
  echo "FAIL: LiteLLM not deployed. Run ./scripts/api-up.sh first." >&2
  exit 1
}

# Verify LiteLLM is responding before bringing up OpenHands
KEY=$(cat .litellm-key)
HTTP=$(curl -sS -m 3 -o /dev/null -w "%{http_code}" \
  "http://localhost:4000/health/readiness" 2>/dev/null || echo 000)
if [ "$HTTP" != "200" ]; then
  echo "FAIL: LiteLLM at localhost:4000 returned HTTP $HTTP." >&2
  echo "  Run ./scripts/api-up.sh and retry." >&2
  exit 1
fi

MODEL="${ZDR_MODEL:-sonnet-api}"
WORKSPACE="${WORKSPACE:-$(cd .. && pwd)}"
# OpenHands versioning: app is at docker.openhands.dev/openhands/openhands:<v>;
# the sandbox "agent-server" runtime image is at ghcr.io/openhands/agent-server
# and is pinned separately. Bump these together when upgrading.
OPENHANDS_VERSION="${OPENHANDS_VERSION:-1.7}"
AGENT_SERVER_TAG="${AGENT_SERVER_TAG:-1.19.1-python}"

echo "═ Starting OpenHands"
echo "  App version:    $OPENHANDS_VERSION"
echo "  Agent server:   $AGENT_SERVER_TAG"
echo "  Model:          $MODEL  (via LiteLLM → Groq/Vast)"
echo "  Workspace:      $WORKSPACE"
echo

# Stop any existing instance so a re-run is idempotent
docker rm -f openhands-app 2>/dev/null || true

# Container talks to LiteLLM on host via host.docker.internal (resolves to host
# loopback on macOS, mapped explicitly on Linux via --add-host below).
docker run -d --pull=always \
  --name openhands-app \
  -p 3000:3000 \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e AGENT_SERVER_IMAGE_TAG="$AGENT_SERVER_TAG" \
  -e LLM_API_BASE="http://host.docker.internal:4000/v1" \
  -e LLM_API_KEY="$KEY" \
  -e LLM_MODEL="openai/${MODEL}" \
  -e LOG_ALL_EVENTS=true \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.openhands:/.openhands" \
  -v "$WORKSPACE:/workspace" \
  --add-host host.docker.internal:host-gateway \
  "docker.openhands.dev/openhands/openhands:${OPENHANDS_VERSION}"

# Wait for OpenHands to bind :3000 (typically <30s)
echo -n "  starting"
for i in $(seq 1 30); do
  HTTP=$(curl -sS -m 1 -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null || echo 000)
  if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
    echo " — ready"
    break
  fi
  echo -n "."
  sleep 2
done

cat <<EOF

═══════════════════════════════════════════════════════════
  OpenHands live.

  Open in browser:  http://localhost:3000

  The web UI will auto-detect the LLM config (Base URL + API Key +
  Model). Drop a project folder in the workspace pane and tell it
  what you want done.

  Workspace mounted: $WORKSPACE
  Model:            $MODEL

  Stop with:        ./scripts/openhands-down.sh
═══════════════════════════════════════════════════════════
EOF
