#!/usr/bin/env bash
# Bring up the API mode (third compute mode after self-hosted pods and
# serverless). No GPU provisioning — LiteLLM routes haiku-api/sonnet-api to
# Groq Cloud, which handles inference with self-serve ZDR.
#
# Usage:  ./scripts/api-up.sh
# Then in Cline: Model ID = haiku-api or sonnet-api.

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set GROQ_API_KEY" >&2; exit 1; }
set -a; . ./.env; set +a
: "${GROQ_API_KEY:?Set GROQ_API_KEY in .env (https://console.groq.com/)}"

for t in docker openssl flock; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: '$t' not on PATH" >&2; exit 1; }
done

echo "═ 1/3  Local LiteLLM master key"
{
  flock -x 200
  if [ ! -f .litellm-key ]; then
    openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
    echo "  ✓ Generated LiteLLM master key (.litellm-key)"
  fi
  LITELLM_MASTER_KEY=$(cat .litellm-key)

  # Ensure LITELLM_MASTER_KEY is in .env-runtime so the container picks it up.
  # Compose merges .env (has GROQ_API_KEY) and .env-runtime; .env-runtime wins.
  touch .env-runtime
  grep -v '^LITELLM_MASTER_KEY=' .env-runtime > .env-runtime.tmp || true
  echo "LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}" >> .env-runtime.tmp
  mv .env-runtime.tmp .env-runtime
} 200>.deploy-lock

echo
echo "═ 2/3  LiteLLM"
if ! docker compose ps litellm --status running 2>/dev/null | grep -q litellm; then
  docker compose up -d
else
  docker compose up -d --force-recreate litellm
fi

# Wait for the container's healthcheck to report healthy (defined in
# docker-compose.yml). Replaces the previous fixed `sleep 3` which raced the
# smoke test on slower hosts.
echo -n "  waiting for LiteLLM to become healthy"
for i in $(seq 1 30); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' zdr-litellm 2>/dev/null || echo "")
  if [ "$STATUS" = "healthy" ]; then
    echo " — ready"
    break
  fi
  echo -n "."
  sleep 2
done
[ "$STATUS" = "healthy" ] || { echo " — TIMEOUT (status=$STATUS); container may still come up shortly. Last 20 log lines:"; docker logs zdr-litellm 2>&1 | tail -20; }
echo "  ✓ LiteLLM on http://localhost:4000"

echo
echo "═ 3/3  Smoke test"
./scripts/smoketest.sh sonnet-api

cat <<EOF

═══════════════════════════════════════════════════════════
  API mode live (Groq Cloud, ZDR via account toggle).

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $(cat .litellm-key)
    Model ID:     sonnet-api   (or: haiku-api)

  ZDR check: https://console.groq.com/settings/data-controls
             (must be enabled BEFORE first request)
  Teardown:  ./scripts/destroy.sh api
═══════════════════════════════════════════════════════════
EOF
