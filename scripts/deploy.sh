#!/usr/bin/env bash
# zdr-coder one-line deploy.
#
# Required:  RUNPOD_API_KEY in .env.
#
# What this does:
#   1. Generate (or reuse) LiteLLM master key + WireGuard keypairs
#   2. Provision RunPod Secure pod with WG keys + endpoint info as env vars
#   3. Discover pod's public IP, write laptop-side wg0.conf
#   4. Start local LiteLLM + WG peer
#   5. Wait for vLLM warmup, run smoketest

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set RUNPOD_API_KEY" >&2; exit 1; }
set -a
. ./.env
set +a

: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env (runpod.io/console/user/settings)}"

# ── Profile defaults: 'sonnet' (DeepSeek V4 Flash on 2x H200) ─────
GPU_IMAGE="${GPU_IMAGE:-ghcr.io/dealright/zdr-coder-gpu:latest}"
GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA H200}"
GPU_COUNT="${GPU_COUNT:-2}"
CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-400}"
MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
TP_SIZE="${TP_SIZE:-2}"
MAX_LEN="${MAX_LEN:-262144}"
POD_NAME="${POD_NAME:-zdr-coder-pod}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

# ── Tool check ────────────────────────────────────────────────
for t in docker curl jq wg; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: '$t' not on PATH" >&2; \
    [ "$t" = "wg" ] && echo "  → brew install wireguard-tools  (macOS)  /  apt install wireguard-tools  (Linux)" >&2; \
    exit 1; }
done

RUNPOD_API="https://api.runpod.io/graphql"
gql() {
  local query="$1"; local vars="$2"
  curl -sS -X POST "$RUNPOD_API" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')"
}

# ── 1. LiteLLM master key + WG laptop keypair (persist locally) ──
echo "═ 1/6  Local keys"
if [ ! -f .litellm-key ]; then
  openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
  echo "  ✓ Generated LiteLLM master key (.litellm-key)"
else
  echo "  ✓ Reusing LiteLLM master key"
fi
LITELLM_MASTER_KEY=$(cat .litellm-key); export LITELLM_MASTER_KEY

if [ ! -f .wg-laptop-private ]; then
  umask 077
  wg genkey > .wg-laptop-private
  wg pubkey < .wg-laptop-private > .wg-laptop-public
  echo "  ✓ Generated laptop WG keypair (.wg-laptop-private/.public)"
else
  echo "  ✓ Reusing laptop WG keypair"
fi
LAPTOP_WG_PRIVKEY=$(cat .wg-laptop-private)
LAPTOP_WG_PUBKEY=$(cat .wg-laptop-public)

# Fresh GPU-side keypair every deploy
GPU_WG_PRIVKEY=$(wg genkey)
GPU_WG_PUBKEY=$(echo "$GPU_WG_PRIVKEY" | wg pubkey)

# ── 2. Provision RunPod pod ──────────────────────────────────
echo
echo "═ 2/6  RunPod pod"
POD_ID=""
if [ -f .runpod-state ]; then
  CACHED=$(grep '^POD_ID=' .runpod-state | cut -d= -f2)
  if [ -n "${CACHED:-}" ]; then
    R=$(gql 'query($id: String!) { pod(input: {podId: $id}) { id desiredStatus } }' "{\"id\":\"$CACHED\"}")
    EX=$(echo "$R" | jq -r '.data.pod.desiredStatus // "MISSING"')
    if [ "$EX" != "MISSING" ] && [ "$EX" != "null" ]; then
      POD_ID="$CACHED"
      echo "  ✓ Reusing existing pod: $POD_ID ($EX)"
    fi
  fi
fi

if [ -z "$POD_ID" ]; then
  echo "  Provisioning new pod ($GPU_COUNT× $GPU_TYPE_ID, model=$MODEL)..."
  PORTS="${WG_LISTEN_PORT}/udp,8000/http"
  VARS=$(jq -n \
    --arg name "$POD_NAME" \
    --arg image "$GPU_IMAGE" \
    --arg gpuType "$GPU_TYPE_ID" \
    --argjson gpuCount "$GPU_COUNT" \
    --argjson disk "$CONTAINER_DISK_GB" \
    --arg ports "$PORTS" \
    --arg wgPriv "$GPU_WG_PRIVKEY" \
    --arg wgPeer "$LAPTOP_WG_PUBKEY" \
    --arg wgPort "$WG_LISTEN_PORT" \
    --arg model "$MODEL" \
    --arg tp "$TP_SIZE" \
    --arg maxLen "$MAX_LEN" \
    '{ input: {
      name: $name, imageName: $image, cloudType: "SECURE",
      gpuTypeId: $gpuType, gpuCount: $gpuCount,
      containerDiskInGb: $disk, volumeInGb: 0,
      minVcpuCount: 8, minMemoryInGb: 32,
      ports: $ports,
      env: [
        {key: "WG_PRIVATE_KEY", value: $wgPriv},
        {key: "WG_PEER_PUBKEY", value: $wgPeer},
        {key: "WG_LISTEN_PORT", value: $wgPort},
        {key: "MODEL",          value: $model},
        {key: "TP_SIZE",        value: $tp},
        {key: "MAX_LEN",        value: $maxLen}
      ]
    } }')
  R=$(gql 'mutation($input: PodFindAndDeployOnDemandInput) { podFindAndDeployOnDemand(input: $input) { id name } }' "$VARS")
  POD_ID=$(echo "$R" | jq -r '.data.podFindAndDeployOnDemand.id // empty')
  [ -n "$POD_ID" ] || { echo "FAIL: pod creation failed:" >&2; echo "$R" | jq . >&2; exit 1; }
  echo "POD_ID=$POD_ID" > .runpod-state
  echo "  ✓ Created: $POD_ID"
fi

# ── 3. Wait for RUNNING + discover public IP/port ──────────────
echo
echo "═ 3/6  Waiting for pod RUNNING + public IP"
STATUS=""; GPU_PUBLIC_IP=""; GPU_WG_PORT=""
for i in $(seq 1 60); do
  R=$(gql 'query($id: String!) { pod(input: {podId: $id}) { desiredStatus runtime { uptimeInSeconds podIp ports { ip isIpPublic privatePort publicPort type } } } }' "{\"id\":\"$POD_ID\"}")
  STATUS=$(echo "$R" | jq -r '.data.pod.desiredStatus // "UNKNOWN"')
  UPTIME=$(echo "$R" | jq -r '.data.pod.runtime.uptimeInSeconds // 0')
  if [ "$STATUS" = "RUNNING" ] && [ "$UPTIME" -gt 0 ]; then
    GPU_PUBLIC_IP=$(echo "$R" | jq -r --arg p "$WG_LISTEN_PORT" '.data.pod.runtime.ports[]? | select(.privatePort == ($p|tonumber) and .isIpPublic == true) | .ip' | head -1)
    GPU_WG_PORT=$(echo "$R" | jq -r --arg p "$WG_LISTEN_PORT" '.data.pod.runtime.ports[]? | select(.privatePort == ($p|tonumber) and .isIpPublic == true) | .publicPort' | head -1)
    if [ -n "$GPU_PUBLIC_IP" ] && [ -n "$GPU_WG_PORT" ]; then
      echo "  ✓ RUNNING. WG endpoint: $GPU_PUBLIC_IP:$GPU_WG_PORT"
      break
    fi
  fi
  printf "  status=%s uptime=%ss (poll %d/60)\r" "$STATUS" "$UPTIME" "$i"
  sleep 10
done
echo
[ -n "$GPU_PUBLIC_IP" ] && [ -n "$GPU_WG_PORT" ] || { echo "FAIL: didn't discover public WG endpoint" >&2; exit 1; }

# ── 4. Write laptop-side wg0.conf ──────────────────────────────
echo
echo "═ 4/6  Writing laptop WG config"
umask 077
cat > wg/laptop.conf <<EOF
[Interface]
PrivateKey = ${LAPTOP_WG_PRIVKEY}
Address = 10.99.0.1/24

[Peer]
PublicKey = ${GPU_WG_PUBKEY}
Endpoint = ${GPU_PUBLIC_IP}:${GPU_WG_PORT}
AllowedIPs = 10.99.0.2/32
PersistentKeepalive = 25
EOF
echo "  ✓ wg/laptop.conf written"

# ── 5. Start local stack ───────────────────────────────────────
echo
echo "═ 5/6  Starting local LiteLLM + WG peer"
docker compose up -d >/dev/null 2>&1
sleep 6
echo "  ✓ Local stack up (LiteLLM on http://localhost:4000)"

# ── 6. Wait for vLLM warmup + smoketest ───────────────────────
echo
echo "═ 6/6  Waiting for vLLM (model load ~10–20 min cold)"
for i in $(seq 1 120); do
  if ./scripts/smoketest.sh >/dev/null 2>&1; then
    echo "  ✓ vLLM responding"
    break
  fi
  printf "  warming (poll %d/120, ~%dm elapsed)\r" "$i" "$((i*10/60))"
  sleep 10
done
echo
./scripts/smoketest.sh

cat <<EOF

═══════════════════════════════════════════════════════════
  Deployment complete.

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $LITELLM_MASTER_KEY
    Model ID:     heavy

  Pod ID:    $POD_ID
  WG peer:   $GPU_PUBLIC_IP:$GPU_WG_PORT  →  10.99.0.2
  Teardown:  ./scripts/destroy.sh
═══════════════════════════════════════════════════════════
EOF
