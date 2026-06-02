#!/usr/bin/env bash
# Stop OpenHands. LiteLLM stays running (stop it separately with
# ./scripts/destroy.sh api if you want to stop the whole stack).

set -euo pipefail

if docker ps --format '{{.Names}}' | grep -q '^openhands-app$'; then
  docker rm -f openhands-app
  echo "  ✓ OpenHands stopped"
else
  echo "  (OpenHands wasn't running)"
fi
