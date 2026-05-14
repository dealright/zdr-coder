#!/usr/bin/env bash
# Entry point for the GPU container.
# 1. Join the Tailscale mesh (no public ports needed on the host)
# 2. Launch vLLM serving the requested model on the tailnet, port 8000
#
# Default: DeepSeek V4 Flash on 2 GPUs (fits 2x H200, 2x H100, 2x A100 80GB, 2x RTX 6000 Pro).
# Upgrade: set MODEL=moonshotai/Kimi-K2.6-Instruct and TP_SIZE=8 for the bigger model on 8x H100.

set -euo pipefail

: "${TS_AUTHKEY:?TS_AUTHKEY required (Tailscale auth key, get from login.tailscale.com/admin/settings/keys)}"
: "${HF_TOKEN:?HF_TOKEN required (Hugging Face token, get from huggingface.co/settings/tokens)}"

TS_HOSTNAME="${TS_HOSTNAME:-zdr-coder-gpu}"
MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
TP_SIZE="${TP_SIZE:-2}"
MAX_LEN="${MAX_LEN:-262144}"
GPU_UTIL="${GPU_UTIL:-0.92}"

echo "[start.sh] Starting Tailscale daemon..."
tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socks5-server=localhost:1055 &
TAILSCALED_PID=$!
sleep 3

echo "[start.sh] Joining tailnet as ${TS_HOSTNAME}..."
tailscale up \
  --authkey="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-routes \
  --ssh=false

echo "[start.sh] Tailscale up. IP: $(tailscale ip -4)"

# Authenticate to Hugging Face for the weights pull
export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"

echo "[start.sh] Launching vLLM: model=${MODEL} TP=${TP_SIZE} MAX_LEN=${MAX_LEN}"
exec python -m vllm.entrypoints.openai.api_server \
  --model "${MODEL}" \
  --tensor-parallel-size "${TP_SIZE}" \
  --max-model-len "${MAX_LEN}" \
  --gpu-memory-utilization "${GPU_UTIL}" \
  --enable-expert-parallel \
  --trust-remote-code \
  --host 0.0.0.0 \
  --port 8000
