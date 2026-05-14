#!/usr/bin/env bash
# One-command deploy.
#   1. Preflight (.env validation)
#   2. Provision RunPod Secure Cloud pod via GraphQL API
#   3. Wait for pod RUNNING + Tailscale convergence + vLLM warmup
#   4. Bring up local LiteLLM via docker compose
#   5. Run end-to-end smoketest
#   6. Print Cline configuration
#
# Idempotent: re-running detects existing pod by name and reuses it.
# State: pod ID is written to .runpod-state (gitignored).

set -euo pipefail
cd "$(dirname "$0")/.."

# ── Load .env ────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "FAIL: .env missing. Run: cp .env.example .env, then fill in values." >&2
  exit 1
fi
set -a
. ./.env
set +a

# ── Required vars ────────────────────────────────────────
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env (get from runpod.io/console/user/settings)}"
: "${TS_AUTHKEY:?Set TS_AUTHKEY in .env}"
: "${HF_TOKEN:?Set HF_TOKEN in .env}"
: "${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"
: "${GPU_IMAGE:?Set GPU_IMAGE=ghcr.io/OWNER/zdr-coder-gpu:latest in .env}"

# ── Defaults (override in .env) ──────────────────────────
TS_HOSTNAME="${TS_HOSTNAME:-zdr-coder-gpu}"
GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA H200}"   # see runpod.io/console/deploy for valid IDs
GPU_COUNT="${GPU_COUNT:-2}"
CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-400}"
MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
TP_SIZE="${TP_SIZE:-2}"
MAX_LEN="${MAX_LEN:-262144}"
POD_NAME="${POD_NAME:-zdr-coder-pod}"

RUNPOD_API="https://api.runpod.io/graphql"

# ── Helpers ──────────────────────────────────────────────
gql() {
  local query="$1"; local vars="$2"
  curl -sS -X POST "$RUNPOD_API" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')"
}

# ── 1. Preflight ─────────────────────────────────────────
echo "═ 1/6  Preflight"
./scripts/preflight.sh

# Verify Docker image is reachable (we don't push, but warn if it's the placeholder)
if [[ "$GPU_IMAGE" == *"YOUR_USER"* ]] || [[ "$GPU_IMAGE" == *"YOUR_REGISTRY"* ]]; then
  echo "FAIL: GPU_IMAGE is still the placeholder. Build & push first:" >&2
  echo "  cd gpu-node && docker build -t ghcr.io/YOUR_USER/zdr-coder-gpu:latest . && docker push ghcr.io/YOUR_USER/zdr-coder-gpu:latest" >&2
  exit 1
fi
echo

# ── 2. Find or create pod ────────────────────────────────
echo "═ 2/6  Checking for existing pod ($POD_NAME)"

# Try to read cached pod ID first
if [ -f .runpod-state ]; then
  CACHED_ID=$(grep '^POD_ID=' .runpod-state | cut -d= -f2)
  if [ -n "${CACHED_ID:-}" ]; then
    STATUS_RESP=$(gql 'query($id: String!) { pod(input: {podId: $id}) { id name desiredStatus } }' "{\"id\":\"$CACHED_ID\"}")
    EXISTING_STATUS=$(echo "$STATUS_RESP" | jq -r '.data.pod.desiredStatus // "MISSING"')
    if [ "$EXISTING_STATUS" != "MISSING" ] && [ "$EXISTING_STATUS" != "null" ]; then
      POD_ID="$CACHED_ID"
      echo "  ✓ Found cached pod: $POD_ID (status: $EXISTING_STATUS)"
    fi
  fi
fi

if [ -z "${POD_ID:-}" ]; then
  echo "  Provisioning new pod on RunPod Secure Cloud..."
  CREATE_VARS=$(jq -n \
    --arg name "$POD_NAME" \
    --arg image "$GPU_IMAGE" \
    --arg gpuType "$GPU_TYPE_ID" \
    --argjson gpuCount "$GPU_COUNT" \
    --argjson disk "$CONTAINER_DISK_GB" \
    --arg tsKey "$TS_AUTHKEY" \
    --arg tsHost "$TS_HOSTNAME" \
    --arg hfTok "$HF_TOKEN" \
    --arg model "$MODEL" \
    --arg tp "$TP_SIZE" \
    --arg maxLen "$MAX_LEN" \
    '{
      input: {
        name: $name,
        imageName: $image,
        cloudType: "SECURE",
        gpuTypeId: $gpuType,
        gpuCount: $gpuCount,
        containerDiskInGb: $disk,
        volumeInGb: 0,
        minVcpuCount: 8,
        minMemoryInGb: 32,
        env: [
          {key: "TS_AUTHKEY", value: $tsKey},
          {key: "TS_HOSTNAME", value: $tsHost},
          {key: "HF_TOKEN",    value: $hfTok},
          {key: "MODEL",       value: $model},
          {key: "TP_SIZE",     value: $tp},
          {key: "MAX_LEN",     value: $maxLen}
        ]
      }
    }')
  CREATE_RESP=$(gql 'mutation($input: PodFindAndDeployOnDemandInput) { podFindAndDeployOnDemand(input: $input) { id name } }' "$CREATE_VARS")
  POD_ID=$(echo "$CREATE_RESP" | jq -r '.data.podFindAndDeployOnDemand.id // empty')
  if [ -z "$POD_ID" ]; then
    echo "FAIL: pod creation failed. Response:" >&2
    echo "$CREATE_RESP" | jq . >&2
    exit 1
  fi
  echo "POD_ID=$POD_ID" > .runpod-state
  echo "  ✓ Created pod: $POD_ID"
fi
echo

# ── 3. Wait for RUNNING ──────────────────────────────────
echo "═ 3/6  Waiting for pod to enter RUNNING"
for i in $(seq 1 60); do
  S=$(gql 'query($id: String!) { pod(input: {podId: $id}) { desiredStatus runtime { uptimeInSeconds } } }' "{\"id\":\"$POD_ID\"}")
  STATUS=$(echo "$S" | jq -r '.data.pod.desiredStatus // "UNKNOWN"')
  UPTIME=$(echo "$S" | jq -r '.data.pod.runtime.uptimeInSeconds // 0')
  if [ "$STATUS" = "RUNNING" ] && [ "$UPTIME" -gt 0 ]; then
    echo "  ✓ Pod RUNNING (uptime ${UPTIME}s)"
    break
  fi
  printf "  status=%s uptime=%ss (poll %d/60)\r" "$STATUS" "$UPTIME" "$i"
  sleep 10
done
echo
[ "$STATUS" = "RUNNING" ] || { echo "FAIL: pod did not reach RUNNING in 10 min" >&2; exit 1; }
echo

# ── 4. Wait for Tailscale convergence ────────────────────
echo "═ 4/6  Waiting for $TS_HOSTNAME on tailnet"
if ! command -v tailscale >/dev/null 2>&1; then
  echo "  (tailscale CLI not on PATH — skipping convergence check; trusting that the pod will join)"
else
  for i in $(seq 1 30); do
    if tailscale status 2>/dev/null | grep -q "$TS_HOSTNAME"; then
      echo "  ✓ $TS_HOSTNAME visible on tailnet"
      break
    fi
    printf "  not yet (poll %d/30)\r" "$i"
    sleep 10
  done
  echo
fi
echo

# ── 5. Bring up local LiteLLM ────────────────────────────
echo "═ 5/6  Starting local LiteLLM"
docker compose up -d
sleep 5
echo

# ── 6. Wait for vLLM warmup + smoketest ──────────────────
echo "═ 6/6  Waiting for vLLM warmup (model load can take 10–20 min)"
ATTEMPTS=120
for i in $(seq 1 $ATTEMPTS); do
  if ./scripts/smoketest.sh >/dev/null 2>&1; then
    echo "  ✓ vLLM responding"
    break
  fi
  printf "  still warming (poll %d/%d, ~%dm elapsed)\r" "$i" "$ATTEMPTS" "$((i*10/60))"
  sleep 10
done
echo
./scripts/smoketest.sh

# ── Done ─────────────────────────────────────────────────
cat <<EOF

═══════════════════════════════════════════════════════════
  Deployment complete.

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $LITELLM_MASTER_KEY
    Model ID:     heavy

  Pod ID:         $POD_ID
  Stop billing:   ./scripts/destroy.sh
═══════════════════════════════════════════════════════════
EOF
