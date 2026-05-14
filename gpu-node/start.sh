#!/usr/bin/env bash
# GPU container entrypoint.
#   1. Bring up WireGuard interface (peer = laptop)
#   2. Launch vLLM listening on the WG interface

set -euo pipefail

: "${WG_PRIVATE_KEY:?WG_PRIVATE_KEY required (set by deploy.sh)}"
: "${WG_PEER_PUBKEY:?WG_PEER_PUBKEY required (set by deploy.sh)}"

MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
TP_SIZE="${TP_SIZE:-2}"
MAX_LEN="${MAX_LEN:-262144}"
GPU_UTIL="${GPU_UTIL:-0.92}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.99.0}"

# Model source: HF-Mirror by default (no token required for public models).
if [ -n "${VLLM_USE_MODELSCOPE:-}" ]; then
  export VLLM_USE_MODELSCOPE=True
  echo "[start.sh] Model source: ModelScope"
elif [ -n "${HF_TOKEN:-}" ]; then
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  echo "[start.sh] Model source: HuggingFace (with token)"
else
  export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
  echo "[start.sh] Model source: HF-Mirror at $HF_ENDPOINT (no token)"
fi

echo "[start.sh] Bringing up WireGuard peer..."
mkdir -p /etc/wireguard
umask 077
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_SUBNET}.2/24
ListenPort = ${WG_LISTEN_PORT}

[Peer]
PublicKey = ${WG_PEER_PUBKEY}
AllowedIPs = ${WG_SUBNET}.1/32
PersistentKeepalive = 25
EOF
wg-quick up wg0
echo "[start.sh] WG up: $(wg show wg0 | head -1)"

echo "[start.sh] Launching vLLM: model=$MODEL TP=$TP_SIZE MAX_LEN=$MAX_LEN"
exec python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_LEN" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --enable-expert-parallel \
  --trust-remote-code \
  --host 0.0.0.0 \
  --port 8000
