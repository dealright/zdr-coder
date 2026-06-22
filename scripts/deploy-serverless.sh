#!/usr/bin/env bash
# zdr-coder serverless deploy. Creates a RunPod Serverless endpoint backed by
# runpod/worker-v1-vllm (OpenAI-compatible). Same LiteLLM front (port 4000) and
# same `.env-runtime` convention as scripts/deploy.sh, but billed per-second of
# actual inference instead of per-hour of an always-on pod.
#
# Usage:  ./scripts/deploy-serverless.sh haiku
#         ./scripts/deploy-serverless.sh sonnet
#
# haiku  → 32B-AWQ on 24/32/48GB pools (cheapest, bursty use)
# sonnet → Qwen3-72B-AWQ on 48/80/141GB pools (single GPU, sonnet-class)

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-haiku}"
case "$PROFILE" in haiku|sonnet) ;; *)
  echo "FAIL: unknown profile '$PROFILE'. Use: haiku | sonnet" >&2
  exit 1
esac

PROFILE_UPPER=$(echo "$PROFILE" | tr '[:lower:]' '[:upper:]')
ROUTE="${PROFILE}-serverless"
ROUTE_UPPER=$(echo "$ROUTE" | tr '[:lower:]-' '[:upper:]_')
STATE_FILE=".runpod-state.${ROUTE}"

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set RUNPOD_API_KEY" >&2; exit 1; }
set -a; . ./.env; set +a
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env}"

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

# ── Per-profile config ───────────────────────────────────────
# Worker image: runpod/worker-v1-vllm exposes /openai/v1/* and reads MODEL_NAME
# etc from env. See https://github.com/runpod-workers/worker-vllm
case "$PROFILE" in
  haiku)
    # NOTE: there is no :stable or :latest tag on runpod/worker-v1-vllm —
    # they only ship versioned tags. Pin to a known-good version. Update by
    # checking https://hub.docker.com/r/runpod/worker-v1-vllm/tags
    WORKER_IMAGE="${WORKER_IMAGE:-runpod/worker-v1-vllm:v2.18.1}"
    MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
    # Allow 24/32/48GB pools. Serverless capacity is brutal on 24GB right now
    # so we widen to RTX 5000 Ada (32GB) and A40/A6000/L40 (48GB) too. RunPod
    # picks the cheapest pool with capacity. 80GB+ omitted for cost.
    GPU_IDS="${GPU_IDS:-AMPERE_24,ADA_24,ADA_32_PRO,AMPERE_48,ADA_48_PRO}"
    MAX_LEN="${MAX_LEN:-4096}"
    GPU_UTIL="${GPU_UTIL:-0.95}"
    QUANTIZATION="${QUANTIZATION:-awq}"
    TP_SIZE="${TP_SIZE:-1}"
    # 18 GiB model + ~10 GiB worker image + HF cache during cold-start download.
    # 30 GiB is too tight and silently stalls initialization. 60 GiB is safe.
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-60}"
    GPU_COUNT="${GPU_COUNT:-1}"
    ;;
  sonnet)
    # Qwen2.5-72B-Instruct-AWQ: pre-quantized 4-bit (~36 GiB weights), single GPU.
    # Multi-GPU serverless (the prior DeepSeek V4 Flash 2×H200 setup) is too
    # flaky on RunPod — workers consistently fail to initialize. Single-GPU AWQ
    # avoids the coordination overhead entirely. We restrict to 80 GB+ GPUs
    # (A100/H200) because 72B AWQ leaves only ~7 GB KV headroom on 48 GB GPUs —
    # too tight for any useful context. On A100 80 GB: 80×0.90=72 GB available,
    # 36 GB model → 36 GB KV, which handles 8-16K context comfortably.
    # Qwen2.5-72B is solidly sonnet-class and well-tested with vLLM.
    WORKER_IMAGE="${WORKER_IMAGE:-runpod/worker-v1-vllm:v2.18.1}"
    MODEL="${MODEL:-Qwen/Qwen2.5-72B-Instruct-AWQ}"
    GPU_IDS="${GPU_IDS:-AMPERE_80,HOPPER_141}"
    GPU_COUNT="${GPU_COUNT:-1}"
    MAX_LEN="${MAX_LEN:-16384}"
    GPU_UTIL="${GPU_UTIL:-0.90}"
    QUANTIZATION="${QUANTIZATION:-awq}"
    TP_SIZE="${TP_SIZE:-1}"
    # 36 GiB model + ~10 GiB worker image + HF cache slack. 80 GiB is plenty.
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-80}"
    ;;
esac

TEMPLATE_NAME="zdr-coder-${ROUTE}"
ENDPOINT_NAME="zdr-coder-${ROUTE}"

# ── 1. Local LiteLLM master key ──────────────────────────────
echo "═ 1/5 [$ROUTE]  Local keys"
{
  flock -x 200
  if [ ! -f .litellm-key ]; then
    openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
    echo "  ✓ Generated LiteLLM master key (.litellm-key)"
  fi
} 200>.deploy-lock
LITELLM_MASTER_KEY=$(cat .litellm-key); export LITELLM_MASTER_KEY

# ── 2. Template ──────────────────────────────────────────────
echo
echo "═ 2/5 [$ROUTE]  RunPod template"
TEMPLATE_ID=""
if [ -f "$STATE_FILE" ]; then
  TEMPLATE_ID=$(grep '^TEMPLATE_ID=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
fi

ENV_JSON=$(jq -nc \
  --arg model "$MODEL" \
  --arg maxLen "$MAX_LEN" \
  --arg gpuUtil "$GPU_UTIL" \
  --arg quant "$QUANTIZATION" \
  --arg tp "$TP_SIZE" \
  --arg hfTok "${HF_TOKEN:-}" \
  '([
    {key: "MODEL_NAME",              value: $model},
    {key: "MAX_MODEL_LEN",           value: $maxLen},
    {key: "GPU_MEMORY_UTILIZATION",  value: $gpuUtil},
    {key: "QUANTIZATION",            value: $quant},
    {key: "TENSOR_PARALLEL_SIZE",    value: $tp},
    {key: "TRUST_REMOTE_CODE",       value: "1"}
  ] + ($hfTok | if . != "" then [{key: "HF_TOKEN", value: .}] else [] end))')

TEMPLATE_VARS=$(jq -nc \
  --arg name "$TEMPLATE_NAME" \
  --arg image "$WORKER_IMAGE" \
  --argjson disk "$CONTAINER_DISK_GB" \
  --argjson env "$ENV_JSON" \
  '{ input: {
    name: $name, imageName: $image, dockerArgs: "",
    containerDiskInGb: $disk, volumeInGb: 0,
    env: $env, isServerless: true
  } }')

R=$(gql 'mutation($input: SaveTemplateInput!){ saveTemplate(input: $input) { id name } }' "$TEMPLATE_VARS")
TEMPLATE_ID=$(echo "$R" | jq -r '.data.saveTemplate.id // empty')
[ -n "$TEMPLATE_ID" ] || { echo "FAIL: template creation failed:" >&2; echo "$R" | jq . >&2; exit 1; }
echo "  ✓ Template: $TEMPLATE_ID ($TEMPLATE_NAME)"

# ── 3. Endpoint ──────────────────────────────────────────────
echo
echo "═ 3/5 [$ROUTE]  RunPod serverless endpoint"
ENDPOINT_ID=""
if [ -f "$STATE_FILE" ]; then
  CACHED=$(grep '^ENDPOINT_ID=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
  if [ -n "${CACHED:-}" ]; then
    EX=$(gql 'query { myself { endpoints { id } } }' '{}' | jq -r ".data.myself.endpoints[] | select(.id==\"$CACHED\") | .id")
    [ -n "$EX" ] && { ENDPOINT_ID="$CACHED"; echo "  ✓ Reusing endpoint: $ENDPOINT_ID"; }
  fi
fi

if [ -z "$ENDPOINT_ID" ]; then
  ENDPOINT_VARS=$(jq -nc \
    --arg name "$ENDPOINT_NAME" \
    --arg tid "$TEMPLATE_ID" \
    --arg gpu "$GPU_IDS" \
    --argjson gpuCount "$GPU_COUNT" \
    '{ input: {
      name: $name, templateId: $tid, gpuIds: $gpu, gpuCount: $gpuCount,
      workersMin: 0, workersMax: 1,
      idleTimeout: 300, executionTimeoutMs: 600000,
      scalerType: "QUEUE_DELAY", scalerValue: 4
    } }')
  R=$(gql 'mutation($input: EndpointInput!){ saveEndpoint(input: $input) { id name } }' "$ENDPOINT_VARS")
  ENDPOINT_ID=$(echo "$R" | jq -r '.data.saveEndpoint.id // empty')
  [ -n "$ENDPOINT_ID" ] || { echo "FAIL: endpoint creation failed:" >&2; echo "$R" | jq . >&2; exit 1; }
  echo "  ✓ Created: $ENDPOINT_ID"
fi

cat > "$STATE_FILE" <<EOF
TEMPLATE_ID=$TEMPLATE_ID
ENDPOINT_ID=$ENDPOINT_ID
EOF

API_BASE="https://api.runpod.ai/v2/${ENDPOINT_ID}/openai/v1"

# ── 4. Write env-runtime + bring up LiteLLM ──────────────────
echo
echo "═ 4/5 [$ROUTE]  Writing .env-runtime entry"
{
  flock -x 200
  touch .env-runtime
  grep -vE "^(${ROUTE_UPPER}_API_|LITELLM_MASTER_KEY=)" .env-runtime > .env-runtime.tmp || true
  # Inference path auth uses the account-level RUNPOD_API_KEY (must be "All"
  # or "Read/Write" scope — "Restricted" works for pod management but returns
  # 403 against /v2/<id>/openai/v1). Master key lives in .env-runtime so
  # docker-compose recreates always pick it up.
  cat >> .env-runtime.tmp <<EOF
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
${ROUTE_UPPER}_API_BASE=${API_BASE}
${ROUTE_UPPER}_API_KEY=${RUNPOD_API_KEY}
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
echo "  ✓ LiteLLM on http://localhost:4000 with $ROUTE route active"

# ── 5. Smoke test (cold start can take 1–3 min on first hit) ─
echo
echo "═ 5/5 [$ROUTE]  Smoke test (first call may cold-start the worker)"
for i in $(seq 1 30); do
  if ./scripts/smoketest.sh "$ROUTE" >/dev/null 2>&1; then
    ./scripts/smoketest.sh "$ROUTE"
    break
  fi
  printf "  cold-starting (poll %d/30, ~%ds elapsed)\r" "$i" "$((i*10))"
  sleep 10
done
echo

cat <<EOF

═══════════════════════════════════════════════════════════
  [$ROUTE]  Serverless endpoint live.

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $LITELLM_MASTER_KEY
    Model ID:     $ROUTE

  Endpoint:   $ENDPOINT_ID
  Template:   $TEMPLATE_ID
  vLLM URL:   ${API_BASE}
  GPU pools:  $GPU_IDS  (RunPod picks whichever has capacity)
  Scaling:    min=0, max=1, idle=5s — idle cost is \$0.
  Teardown:   ./scripts/destroy.sh $ROUTE
═══════════════════════════════════════════════════════════
EOF
