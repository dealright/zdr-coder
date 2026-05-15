#!/usr/bin/env bash
# zdr-coder one-line deploy.
#
# Usage:
#   ./scripts/deploy.sh             # default: sonnet
#   ./scripts/deploy.sh haiku       # smallest/cheapest
#   ./scripts/deploy.sh sonnet      # Sonnet-class
#   ./scripts/deploy.sh opus        # Opus-class
#   ./scripts/deploy.sh all         # all three in parallel
#
# Required:  RUNPOD_API_KEY in .env.
#
# Architecture:
#   Cline (localhost:4000) → LiteLLM (Docker) → HTTPS via RunPod's proxy
#                                              → vLLM on GPU pod (port 8000)
#   Auth: LiteLLM master key (Cline ↔ LiteLLM); VLLM_API_KEY (LiteLLM ↔ vLLM).
#   TLS: handled by RunPod's proxy.runpod.net cert.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-sonnet}"

# Parallel mode.
if [ "$PROFILE" = "all" ]; then
  echo "═ Launching all 3 profiles in parallel"
  "$0" haiku  2>&1 | sed 's/^/[haiku]  /' &
  H_PID=$!
  "$0" sonnet 2>&1 | sed 's/^/[sonnet] /' &
  S_PID=$!
  "$0" opus   2>&1 | sed 's/^/[opus]   /' &
  O_PID=$!
  wait $H_PID $S_PID $O_PID
  exit
fi

# ── Per-profile defaults ──────────────────────────────────────
case "$PROFILE" in
  haiku)
    # Qwen2.5-Coder-32B-AWQ (~20GB INT4). RTX A5000 24GB fits weights + 16K KV.
    # Qwen3-Coder series ships mainly as MoE; their official 32B-dense AWQ is on
    # the 2.5 line. Override in .env if you want a different model.
    # When A40/A6000 (48GB) is in stock, you can raise MAX_LEN to 64K+.
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA RTX A5000}"
    GPU_COUNT="${GPU_COUNT:-1}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-120}"
    MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
    TP_SIZE="${TP_SIZE:-1}"
    MAX_LEN="${MAX_LEN:-16384}"
    ;;
  sonnet)
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA A100-SXM4-80GB}"
    GPU_COUNT="${GPU_COUNT:-2}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-400}"
    MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
    TP_SIZE="${TP_SIZE:-2}"
    MAX_LEN="${MAX_LEN:-262144}"
    ;;
  opus)
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA H100 80GB HBM3}"
    GPU_COUNT="${GPU_COUNT:-8}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-700}"
    MODEL="${MODEL:-moonshotai/Kimi-K2.6-Instruct}"
    TP_SIZE="${TP_SIZE:-8}"
    MAX_LEN="${MAX_LEN:-131072}"
    ;;
  *)
    echo "FAIL: unknown profile '$PROFILE'. Use: haiku | sonnet | opus | all" >&2
    exit 1
    ;;
esac

POD_NAME="zdr-coder-${PROFILE}"
STATE_FILE=".runpod-state.${PROFILE}"
KEY_FILE=".vllm-key.${PROFILE}"
PROFILE_UPPER=$(echo "$PROFILE" | tr '[:lower:]' '[:upper:]')

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set RUNPOD_API_KEY" >&2; exit 1; }
set -a
. ./.env
set +a
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env}"

# Use SHA-tagged image by default — guarantees RunPod hosts pull fresh content
# (the `:latest` tag is reused across builds and RunPod caches it aggressively).
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$GIT_SHA" ]; then
  GPU_IMAGE="${GPU_IMAGE:-ghcr.io/dealright/zdr-coder-gpu:sha-${GIT_SHA}}"
else
  GPU_IMAGE="${GPU_IMAGE:-ghcr.io/dealright/zdr-coder-gpu:latest}"
fi

# ── Tools ─────────────────────────────────────────────────────
for t in docker curl jq openssl flock; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: '$t' not on PATH" >&2; exit 1; }
done

RUNPOD_API="https://api.runpod.io/graphql"
gql() {
  curl -sS -X POST "$RUNPOD_API" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
}

# ── 1. Local keys (shared LiteLLM + per-profile vLLM bearer) ─
echo "═ 1/6 [$PROFILE]  Local keys"
{
  flock -x 200
  if [ ! -f .litellm-key ]; then
    openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
    echo "  ✓ Generated LiteLLM master key (.litellm-key)"
  fi
  if [ ! -f "$KEY_FILE" ]; then
    openssl rand -hex 32 > "$KEY_FILE"
    echo "  ✓ Generated vLLM bearer for $PROFILE ($KEY_FILE)"
  fi
} 200>.deploy-lock
LITELLM_MASTER_KEY=$(cat .litellm-key); export LITELLM_MASTER_KEY
VLLM_API_KEY=$(cat "$KEY_FILE")

# ── 2. Provision RunPod pod ──────────────────────────────────
echo
echo "═ 2/6 [$PROFILE]  RunPod pod"
POD_ID=""
if [ -f "$STATE_FILE" ]; then
  CACHED=$(grep '^POD_ID=' "$STATE_FILE" | cut -d= -f2)
  if [ -n "${CACHED:-}" ]; then
    R=$(gql 'query($id: String!) { pod(input: {podId: $id}) { id desiredStatus } }' "{\"id\":\"$CACHED\"}")
    EX=$(echo "$R" | jq -r '.data.pod.desiredStatus // "MISSING"')
    [ "$EX" != "MISSING" ] && [ "$EX" != "null" ] && { POD_ID="$CACHED"; echo "  ✓ Reusing pod: $POD_ID ($EX)"; }
  fi
fi

if [ -z "$POD_ID" ]; then
  echo "  Provisioning ${GPU_COUNT}x ${GPU_TYPE_ID}, model=${MODEL}..."
  VARS=$(jq -n \
    --arg name "$POD_NAME" \
    --arg image "$GPU_IMAGE" \
    --arg gpuType "$GPU_TYPE_ID" \
    --argjson gpuCount "$GPU_COUNT" \
    --argjson disk "$CONTAINER_DISK_GB" \
    --arg vllmKey "$VLLM_API_KEY" \
    --arg model "$MODEL" \
    --arg tp "$TP_SIZE" \
    --arg maxLen "$MAX_LEN" \
    --arg hfTok "${HF_TOKEN:-}" \
    '{ input: {
      name: $name, imageName: $image, cloudType: "SECURE",
      gpuTypeId: $gpuType, gpuCount: $gpuCount,
      containerDiskInGb: $disk, volumeInGb: 0,
      ports: "8000/http",
      env: ([
        {key: "VLLM_API_KEY", value: $vllmKey},
        {key: "MODEL",        value: $model},
        {key: "TP_SIZE",      value: $tp},
        {key: "MAX_LEN",      value: $maxLen}
      ] + ($hfTok | if . != "" then [{key: "HF_TOKEN", value: .}] else [] end))
    } }')
  R=$(gql 'mutation($input: PodFindAndDeployOnDemandInput) { podFindAndDeployOnDemand(input: $input) { id name } }' "$VARS")
  POD_ID=$(echo "$R" | jq -r '.data.podFindAndDeployOnDemand.id // empty')
  [ -n "$POD_ID" ] || { echo "FAIL: pod creation failed:" >&2; echo "$R" | jq . >&2; exit 1; }
  echo "POD_ID=$POD_ID" > "$STATE_FILE"
  echo "  ✓ Created: $POD_ID"
fi

# Proxy URL pattern: https://[POD_ID]-[PORT].proxy.runpod.net
API_BASE="https://${POD_ID}-8000.proxy.runpod.net/v1"

# ── 3. Wait for RUNNING ──────────────────────────────────────
echo
echo "═ 3/6 [$PROFILE]  Waiting for pod RUNNING"
STATUS=""
for i in $(seq 1 60); do
  R=$(gql 'query($id: String!) { pod(input: {podId: $id}) { desiredStatus runtime { uptimeInSeconds } } }' "{\"id\":\"$POD_ID\"}")
  STATUS=$(echo "$R" | jq -r '.data.pod.desiredStatus // "UNKNOWN"')
  UPTIME=$(echo "$R" | jq -r '.data.pod.runtime.uptimeInSeconds // 0')
  if [ "$STATUS" = "RUNNING" ] && [ "$UPTIME" -gt 0 ]; then
    echo "  ✓ RUNNING (uptime ${UPTIME}s)"
    break
  fi
  printf "  status=%s uptime=%ss (poll %d/60)\r" "$STATUS" "$UPTIME" "$i"
  sleep 10
done
echo
[ "$STATUS" = "RUNNING" ] || { echo "FAIL: pod did not reach RUNNING in 10 min" >&2; exit 1; }

# ── 4. Write env-runtime + bring up LiteLLM ──────────────────
echo
echo "═ 4/6 [$PROFILE]  Writing .env-runtime entry"
{
  flock -x 200
  # Preserve any existing per-profile entries, overwrite this profile's only.
  touch .env-runtime
  grep -v "^${PROFILE_UPPER}_API_" .env-runtime > .env-runtime.tmp || true
  cat >> .env-runtime.tmp <<EOF
${PROFILE_UPPER}_API_BASE=${API_BASE}
${PROFILE_UPPER}_API_KEY=${VLLM_API_KEY}
EOF
  mv .env-runtime.tmp .env-runtime

  if ! docker compose ps litellm --status running 2>/dev/null | grep -q litellm; then
    docker compose up -d >/dev/null 2>&1
    sleep 3
  else
    docker compose up -d --force-recreate litellm >/dev/null 2>&1
    sleep 3
  fi
} 200>.deploy-lock
echo "  ✓ LiteLLM on http://localhost:4000 with $PROFILE route active"

# ── 5. Wait for vLLM warmup ──────────────────────────────────
echo
echo "═ 5/6 [$PROFILE]  Waiting for vLLM (~10–20 min cold)"
for i in $(seq 1 120); do
  if ./scripts/smoketest.sh "$PROFILE" >/dev/null 2>&1; then
    echo "  ✓ vLLM responding"
    break
  fi
  printf "  warming (poll %d/120, ~%dm elapsed)\r" "$i" "$((i*10/60))"
  sleep 10
done
echo

# ── 6. Final smoke test ──────────────────────────────────────
echo "═ 6/6 [$PROFILE]  Smoke test"
./scripts/smoketest.sh "$PROFILE"

cat <<EOF

═══════════════════════════════════════════════════════════
  [$PROFILE]  Deployment complete.

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $LITELLM_MASTER_KEY
    Model ID:     $PROFILE        (or: haiku / sonnet / opus / heavy / plan)

  Pod:        $POD_ID
  vLLM URL:   ${API_BASE} (via RunPod HTTPS proxy)
  Teardown:   ./scripts/destroy.sh $PROFILE   (or 'all')
═══════════════════════════════════════════════════════════
EOF
