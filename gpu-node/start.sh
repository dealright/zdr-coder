#!/usr/bin/env bash
# GPU container entrypoint.
# Runs vLLM on :8000 with bearer-token auth. RunPod's HTTPS proxy fronts the port
# at https://[POD_ID]-8000.proxy.runpod.net — LiteLLM on the laptop sends the
# token on every request.

set -euo pipefail

: "${VLLM_API_KEY:?VLLM_API_KEY required (set by deploy.sh)}"

MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
TP_SIZE="${TP_SIZE:-2}"
MAX_LEN="${MAX_LEN:-262144}"
GPU_UTIL="${GPU_UTIL:-0.92}"

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

# `--enable-expert-parallel` is a no-op on dense models and required for MoE.
# Pass it conditionally so dense models (Qwen3-Coder-32B) don't get confused.
EXTRA_ARGS=()
case "${MODEL,,}" in
  *kimi*|*deepseek-v4*|*deepseek-v3*|*moe*|*mixtral*|*glm-5*)
    EXTRA_ARGS+=(--enable-expert-parallel)
    ;;
esac

echo "[start.sh] Launching vLLM: model=$MODEL TP=$TP_SIZE MAX_LEN=$MAX_LEN"
exec python3 -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_LEN" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --trust-remote-code \
  --host 0.0.0.0 --port 8000 \
  --api-key "$VLLM_API_KEY" \
  "${EXTRA_ARGS[@]}"
