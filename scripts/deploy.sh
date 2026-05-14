#!/usr/bin/env bash
# zdr-coder one-line deploy.
#
# Usage:
#   ./scripts/deploy.sh             # default: sonnet
#   ./scripts/deploy.sh haiku       # smallest/cheapest
#   ./scripts/deploy.sh sonnet      # Sonnet-class
#   ./scripts/deploy.sh opus        # Opus-class
#   ./scripts/deploy.sh all         # all three in parallel (3 terminals worth)
#
# Required:  RUNPOD_API_KEY in .env.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-sonnet}"

# Parallel mode: spawn the three profiles in the background and wait.
if [ "$PROFILE" = "all" ]; then
  echo "═ Launching all 3 profiles in parallel"
  echo "  Each runs independently; output is interleaved. To see logs per-profile,"
  echo "  run in 3 separate terminals: ./scripts/deploy.sh {haiku,sonnet,opus}"
  echo
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
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA RTX A5000}"
    GPU_COUNT="${GPU_COUNT:-1}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-120}"
    MODEL="${MODEL:-Qwen/Qwen3-Coder-32B-Instruct}"
    TP_SIZE="${TP_SIZE:-1}"
    MAX_LEN="${MAX_LEN:-65536}"
    WG_SUBNET=10.99.10
    ;;
  sonnet)
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA A100 80GB PCIe}"
    GPU_COUNT="${GPU_COUNT:-2}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-400}"
    MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
    TP_SIZE="${TP_SIZE:-2}"
    MAX_LEN="${MAX_LEN:-262144}"
    WG_SUBNET=10.99.20
    ;;
  opus)
    GPU_TYPE_ID="${GPU_TYPE_ID:-NVIDIA H100 80GB HBM3}"
    GPU_COUNT="${GPU_COUNT:-8}"
    CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-700}"
    MODEL="${MODEL:-moonshotai/Kimi-K2.6-Instruct}"
    TP_SIZE="${TP_SIZE:-8}"
    MAX_LEN="${MAX_LEN:-131072}"
    WG_SUBNET=10.99.30
    ;;
  *)
    echo "FAIL: unknown profile '$PROFILE'. Use: haiku | sonnet | opus | all" >&2
    exit 1
    ;;
esac

POD_NAME="zdr-coder-${PROFILE}"
STATE_FILE=".runpod-state.${PROFILE}"
WG_CONF="wg/${PROFILE}.conf"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set RUNPOD_API_KEY" >&2; exit 1; }
set -a
. ./.env
set +a
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env}"

GPU_IMAGE="${GPU_IMAGE:-ghcr.io/dealright/zdr-coder-gpu:latest}"

# ── Tools ─────────────────────────────────────────────────────
for t in docker curl jq wg openssl flock; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: '$t' not on PATH" >&2; \
    [ "$t" = "wg" ] && echo "  → brew install wireguard-tools (macOS) / apt install wireguard-tools (Linux)" >&2; \
    [ "$t" = "flock" ] && echo "  → brew install flock (macOS) / built-in on Linux" >&2; \
    exit 1; }
done

RUNPOD_API="https://api.runpod.io/graphql"
gql() {
  curl -sS -X POST "$RUNPOD_API" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
}

# ── 1. Local keys (shared LiteLLM key + per-deploy WG keys) ───
echo "═ 1/6 [$PROFILE]  Local keys"
{
  flock -x 200
  if [ ! -f .litellm-key ]; then
    openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
    echo "  ✓ Generated LiteLLM master key (.litellm-key)"
  fi
  if [ ! -f .wg-laptop-private ]; then
    umask 077
    wg genkey > .wg-laptop-private
    wg pubkey < .wg-laptop-private > .wg-laptop-public
    echo "  ✓ Generated laptop WG keypair (.wg-laptop-private/.public)"
  fi
} 200>.deploy-lock
LITELLM_MASTER_KEY=$(cat .litellm-key); export LITELLM_MASTER_KEY
LAPTOP_WG_PRIVKEY=$(cat .wg-laptop-private)
LAPTOP_WG_PUBKEY=$(cat .wg-laptop-public)

# Fresh GPU-side keypair every deploy of this profile
GPU_WG_PRIVKEY=$(wg genkey)
GPU_WG_PUBKEY=$(echo "$GPU_WG_PRIVKEY" | wg pubkey)

# ── 2. Provision RunPod pod for this profile ──────────────────
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
    --arg ports "${WG_LISTEN_PORT}/udp,8000/http" \
    --arg wgPriv "$GPU_WG_PRIVKEY" \
    --arg wgPeer "$LAPTOP_WG_PUBKEY" \
    --arg wgPort "$WG_LISTEN_PORT" \
    --arg wgSubnet "$WG_SUBNET" \
    --arg model "$MODEL" \
    --arg tp "$TP_SIZE" \
    --arg maxLen "$MAX_LEN" \
    '{ input: {
      name: $name, imageName: $image, cloudType: "SECURE",
      gpuTypeId: $gpuType, gpuCount: $gpuCount,
      containerDiskInGb: $disk, volumeInGb: 0,
      ports: $ports,
      env: [
        {key: "WG_PRIVATE_KEY", value: $wgPriv},
        {key: "WG_PEER_PUBKEY", value: $wgPeer},
        {key: "WG_LISTEN_PORT", value: $wgPort},
        {key: "WG_SUBNET",      value: $wgSubnet},
        {key: "MODEL",          value: $model},
        {key: "TP_SIZE",        value: $tp},
        {key: "MAX_LEN",        value: $maxLen}
      ]
    } }')
  R=$(gql 'mutation($input: PodFindAndDeployOnDemandInput) { podFindAndDeployOnDemand(input: $input) { id name } }' "$VARS")
  POD_ID=$(echo "$R" | jq -r '.data.podFindAndDeployOnDemand.id // empty')
  [ -n "$POD_ID" ] || { echo "FAIL: pod creation failed:" >&2; echo "$R" | jq . >&2; exit 1; }
  echo "POD_ID=$POD_ID" > "$STATE_FILE"
  echo "  ✓ Created: $POD_ID"
fi

# ── 3. Wait for RUNNING + discover endpoint ──────────────────
echo
echo "═ 3/6 [$PROFILE]  Waiting for pod RUNNING + public IP"
STATUS=""; GPU_PUBLIC_IP=""; GPU_WG_PORT=""
for i in $(seq 1 60); do
  R=$(gql 'query($id: String!) { pod(input: {podId: $id}) { desiredStatus runtime { uptimeInSeconds podIp ports { ip isIpPublic privatePort publicPort type } } } }' "{\"id\":\"$POD_ID\"}")
  STATUS=$(echo "$R" | jq -r '.data.pod.desiredStatus // "UNKNOWN"')
  UPTIME=$(echo "$R" | jq -r '.data.pod.runtime.uptimeInSeconds // 0')
  if [ "$STATUS" = "RUNNING" ] && [ "$UPTIME" -gt 0 ]; then
    GPU_PUBLIC_IP=$(echo "$R" | jq -r --arg p "$WG_LISTEN_PORT" '.data.pod.runtime.ports[]? | select(.privatePort == ($p|tonumber) and .isIpPublic == true) | .ip' | head -1)
    GPU_WG_PORT=$(echo "$R" | jq -r --arg p "$WG_LISTEN_PORT" '.data.pod.runtime.ports[]? | select(.privatePort == ($p|tonumber) and .isIpPublic == true) | .publicPort' | head -1)
    [ -n "$GPU_PUBLIC_IP" ] && [ -n "$GPU_WG_PORT" ] && { echo "  ✓ RUNNING. WG endpoint: $GPU_PUBLIC_IP:$GPU_WG_PORT"; break; }
  fi
  printf "  status=%s uptime=%ss (poll %d/60)\r" "$STATUS" "$UPTIME" "$i"
  sleep 10
done
echo
[ -n "$GPU_PUBLIC_IP" ] && [ -n "$GPU_WG_PORT" ] || { echo "FAIL: didn't discover public WG endpoint" >&2; exit 1; }

# ── 4. Write WG conf + reload wg-laptop ──────────────────────
echo
echo "═ 4/6 [$PROFILE]  Writing $WG_CONF"
umask 077
cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${LAPTOP_WG_PRIVKEY}
Address = ${WG_SUBNET}.1/24

[Peer]
PublicKey = ${GPU_WG_PUBKEY}
Endpoint = ${GPU_PUBLIC_IP}:${GPU_WG_PORT}
AllowedIPs = ${WG_SUBNET}.2/32
PersistentKeepalive = 25
EOF

# Bring up the laptop side. Serialize compose operations across parallel deploys.
{
  flock -x 200
  if ! docker compose ps wg-laptop --status running 2>/dev/null | grep -q wg-laptop; then
    echo "  Starting docker compose..."
    docker compose up -d >/dev/null 2>&1
    sleep 4
  fi
  # Bring this profile's interface up inside the container (no restart needed)
  if docker compose exec -T wg-laptop wg show "$PROFILE" >/dev/null 2>&1; then
    docker compose exec -T wg-laptop wg-quick down "/config/wg_confs/${PROFILE}.conf" >/dev/null 2>&1 || true
  fi
  docker compose exec -T wg-laptop wg-quick up "/config/wg_confs/${PROFILE}.conf" >/dev/null 2>&1 \
    || { echo "FAIL: couldn't bring up wg interface '$PROFILE' inside container" >&2; exit 1; }
} 200>.deploy-lock
echo "  ✓ WG interface '$PROFILE' up; LiteLLM on http://localhost:4000"

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

  Pod ID:    $POD_ID
  WG peer:   $GPU_PUBLIC_IP:$GPU_WG_PORT  →  ${WG_SUBNET}.2
  Teardown:  ./scripts/destroy.sh $PROFILE   (or 'all')
═══════════════════════════════════════════════════════════
EOF
