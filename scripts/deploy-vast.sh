#!/usr/bin/env bash
# zdr-coder Vast.ai deploy. Same LiteLLM front (port 4000) and .env-runtime
# convention as scripts/deploy.sh — different upstream provider.
#
# Vast.ai is a marketplace of independent hosts running datacenter and
# consumer GPUs, billed per-second with no commitment. We pick "verified"
# offers (datacenter-grade hosts) and rent the cheapest one matching each
# profile's GPU spec. See https://vast.ai/.
#
# Usage:  ./scripts/deploy-vast.sh [haiku|sonnet|opus]   (default: haiku)
#
# Required:  VAST_API_KEY in .env (https://cloud.vast.ai/account/).

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-haiku}"
case "$PROFILE" in haiku|sonnet|opus) ;; *)
  echo "FAIL: unknown profile '$PROFILE'. Use: haiku | sonnet | opus" >&2; exit 1 ;;
esac

ROUTE="${PROFILE}-vast"
ROUTE_UPPER=$(echo "$ROUTE" | tr '[:lower:]-' '[:upper:]_')
STATE_FILE=".runpod-state.${ROUTE}"  # reuse the gitignored .runpod-state.* prefix
KEY_FILE=".vllm-key.${ROUTE}"

[ -f .env ] || { echo "FAIL: .env missing. cp .env.example .env, set VAST_API_KEY" >&2; exit 1; }
set -a; . ./.env; set +a
: "${VAST_API_KEY:?Set VAST_API_KEY in .env (https://cloud.vast.ai/account/)}"

for t in docker curl jq openssl flock; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: '$t' not on PATH" >&2; exit 1; }
done

VAST_API="https://console.vast.ai/api/v0"
vast() {
  # vast METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "${VAST_API}${path}" \
      -H "Authorization: Bearer $VAST_API_KEY" -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sS -X "$method" "${VAST_API}${path}" \
      -H "Authorization: Bearer $VAST_API_KEY"
  fi
}

# ── Image tag ─────────────────────────────────────────────────
# Default to :latest — build workflow pushes it on every main-branch build.
# Override with GPU_IMAGE=...sha-XXXXX for reproducible production pins.
GPU_IMAGE="${GPU_IMAGE:-ghcr.io/dealright/zdr-coder-gpu:latest}"

# ── Per-profile defaults (same surface as deploy.sh) ────────
case "$PROFILE" in
  haiku)
    # 1x 24GB card; RTX 4090 is the cheapest verified Ada Lovelace option.
    GPU_NAME="${GPU_NAME:-RTX 4090}"
    NUM_GPUS="${NUM_GPUS:-1}"
    GPU_RAM_MB="${GPU_RAM_MB:-23000}"     # 24GB minus ECC overhead
    MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
    TP_SIZE="${TP_SIZE:-1}"
    MAX_LEN="${MAX_LEN:-4096}"
    GPU_UTIL="${GPU_UTIL:-0.95}"
    DISK_GB="${DISK_GB:-120}"
    ;;
  sonnet)
    # 4x 80GB on a single host for TP=4. H100 SXM (or H200 / B200) is
    # required, NOT A100 — DeepSeek V4 Flash ships in FP8 and its deepgemm
    # kernels reject Ampere with "Unsupported architecture". The Vast
    # marketplace usually has 1-3 hosts in this class; price floor ~$5.87/hr.
    GPU_NAME="${GPU_NAME:-H100 SXM}"
    NUM_GPUS="${NUM_GPUS:-4}"
    GPU_RAM_MB="${GPU_RAM_MB:-81000}"
    MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}"
    TP_SIZE="${TP_SIZE:-4}"
    MAX_LEN="${MAX_LEN:-65536}"
    GPU_UTIL="${GPU_UTIL:-0.95}"
    # 149 GiB model + 50 GiB buffer.
    DISK_GB="${DISK_GB:-200}"
    ;;
  opus)
    # 8x 80GB on a single host for TP=8. H100 SXM is the target; override
    # GPU_NAME="H200" + NUM_GPUS=4 if you want the H200 fallback (560GB on
    # 4 cards > 554GB Kimi K2.6 weights, often cheaper per total VRAM).
    GPU_NAME="${GPU_NAME:-H100 SXM}"
    NUM_GPUS="${NUM_GPUS:-8}"
    GPU_RAM_MB="${GPU_RAM_MB:-81000}"
    MODEL="${MODEL:-moonshotai/Kimi-K2.6}"
    TP_SIZE="${TP_SIZE:-8}"
    MAX_LEN="${MAX_LEN:-65536}"
    GPU_UTIL="${GPU_UTIL:-0.95}"
    DISK_GB="${DISK_GB:-700}"
    ;;
esac

# ── 1. Local keys ────────────────────────────────────────────
echo "═ 1/6 [$ROUTE]  Local keys"
{
  flock -x 200
  if [ ! -f .litellm-key ]; then
    openssl rand -hex 32 | awk '{print "sk-"$0}' > .litellm-key
    echo "  ✓ Generated LiteLLM master key (.litellm-key)"
  fi
  if [ ! -f "$KEY_FILE" ]; then
    openssl rand -hex 32 > "$KEY_FILE"
    echo "  ✓ Generated vLLM bearer for $ROUTE ($KEY_FILE)"
  fi
} 200>.deploy-lock
LITELLM_MASTER_KEY=$(cat .litellm-key); export LITELLM_MASTER_KEY
VLLM_API_KEY=$(cat "$KEY_FILE")

# ── 2. Find an offer (or reuse cached instance) ──────────────
echo
echo "═ 2/6 [$ROUTE]  Vast.ai offer search"
INSTANCE_ID=""
if [ -f "$STATE_FILE" ]; then
  CACHED=$(grep '^INSTANCE_ID=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
  if [ -n "${CACHED:-}" ]; then
    EX=$(vast GET "/instances/${CACHED}/" | jq -r '.instances.id // .id // empty')
    [ -n "$EX" ] && { INSTANCE_ID="$CACHED"; echo "  ✓ Reusing instance: $INSTANCE_ID"; }
  fi
fi

if [ -z "$INSTANCE_ID" ]; then
  # Filter tier:
  #  - Default: datacenter: true → Vast Secure Cloud (ISO 27001 / Tier 3-4,
  #    BAA-eligible). This is what the project's ZDR/HIPAA story rides on.
  #  - VAST_ALLOW_MARKETPLACE=1 → verified: true → broader marketplace
  #    (still passes Vast's basic reliability check, but the host operator
  #    is an individual/residential, not an attested datacenter). Use this
  #    only when SC inventory is dry and you accept the ZDR downgrade for
  #    that workload.
  # Plain `verified` is NOT a compliance attestation — never use it as a
  # substitute for the SC posture in production.
  # eq (not gte) on num_gpus — Vast rents the whole physical host.
  # cuda_max_good: 13.0 for default (matches our 12.8+ container, consumer
  # Ada has no CUDA forward-compat). Datacenter cards (A100/H100) support
  # forward-compat so the marketplace path can relax to 12.4 if needed.
  if [ "${VAST_ALLOW_MARKETPLACE:-0}" = "1" ]; then
    echo "  ⚠ VAST_ALLOW_MARKETPLACE=1 — accepting any rentable host (ZDR posture downgraded)"
    SEARCH=$(jq -nc \
      --arg gpu "$GPU_NAME" \
      --argjson nGpus "$NUM_GPUS" \
      --argjson ram "$GPU_RAM_MB" \
      --argjson disk "$DISK_GB" \
      '{
        rentable: {eq: true},
        gpu_name: {eq: $gpu},
        num_gpus: {eq: $nGpus},
        gpu_ram: {gte: $ram},
        direct_port_count: {gte: 1},
        disk_space: {gte: $disk},
        inet_down: {gte: 500},
        cuda_max_good: {gte: 12.4},
        type: "on-demand",
        order: [["dph_total", "asc"]],
        limit: 5
      }')
  else
    SEARCH=$(jq -nc \
      --arg gpu "$GPU_NAME" \
      --argjson nGpus "$NUM_GPUS" \
      --argjson ram "$GPU_RAM_MB" \
      --argjson disk "$DISK_GB" \
      '{
        datacenter: {eq: true},
        rentable: {eq: true},
        gpu_name: {eq: $gpu},
        num_gpus: {eq: $nGpus},
        gpu_ram: {gte: $ram},
        direct_port_count: {gte: 1},
        disk_space: {gte: $disk},
        inet_down: {gte: 500},
        cuda_max_good: {gte: 13.0},
        type: "on-demand",
        order: [["dph_total", "asc"]],
        limit: 5
      }')
  fi
  R=$(vast POST "/bundles/" "$SEARCH")
  OFFER_ID=$(echo "$R" | jq -r '.offers[0].id // empty')
  OFFER_PRICE=$(echo "$R" | jq -r '.offers[0].dph_total // empty')
  OFFER_GPUS=$(echo "$R" | jq -r '.offers[0].num_gpus // empty')
  OFFER_GEO=$(echo "$R" | jq -r '.offers[0].geolocation // "unknown"')
  if [ -z "$OFFER_ID" ]; then
    echo "FAIL: no verified on-demand offers matching ${NUM_GPUS}× $GPU_NAME" >&2
    echo "  → Try a different GPU_NAME (RTX 5090, A40, L40S, H200, B200)" >&2
    echo "  → Or relax verified=true via VAST_VERIFIED_ONLY=0 (not implemented yet)" >&2
    exit 1
  fi
  echo "  ✓ Offer picked: $OFFER_ID — ${OFFER_GPUS}× $GPU_NAME @ \$$OFFER_PRICE/hr ($OFFER_GEO)"

  # Detect pre-populated volume from vol-up.sh. If present we pin to that
  # host (volumes are machine_id-scoped) and mount /workspace/hf-cache so
  # vLLM reads weights from local disk instead of re-downloading from HF.
  VOL_STATE=".runpod-state.${ROUTE}-volume"
  VOL_MOUNT_JSON='[]'
  if [ -f "$VOL_STATE" ]; then
    VOL_ID=$(grep '^VOLUME_ID=' "$VOL_STATE" | cut -d= -f2)
    VOL_MACHINE=$(grep '^MACHINE_ID=' "$VOL_STATE" | cut -d= -f2)
    if [ -n "$VOL_ID" ] && [ -n "$VOL_MACHINE" ]; then
      VOL_MOUNT_JSON="[{\"volume_id\":$VOL_ID,\"mount_path\":\"/workspace/hf-cache\"}]"
      echo "  ✓ Volume $VOL_ID detected — pinning to machine_id=$VOL_MACHINE"
      # Re-search filtered to that specific host so the picked offer is on it.
      RESEARCH=$(jq -nc --argjson m "$VOL_MACHINE" '{rentable:{eq:true},machine_id:{eq:$m},type:"on-demand",limit:1}')
      OFFER_ID=$(vast POST "/bundles/" "$RESEARCH" | jq -r '.offers[0].id // empty')
      [ -n "$OFFER_ID" ] || { echo "FAIL: pinned host $VOL_MACHINE not rentable right now" >&2; exit 1; }
    fi
  fi

  # Build env vars + onstart command. start.sh reads MODEL etc; when a
  # volume is mounted, point HF_HOME at it so vLLM uses cached weights.
  ONSTART='env >> /etc/environment && [ -d /workspace/hf-cache ] && export HF_HOME=/workspace/hf-cache; /start.sh'
  CREATE_BODY=$(jq -nc \
    --arg image "$GPU_IMAGE" \
    --arg onstart "$ONSTART" \
    --argjson disk "$DISK_GB" \
    --arg model "$MODEL" \
    --arg maxLen "$MAX_LEN" \
    --arg gpuUtil "$GPU_UTIL" \
    --arg tp "$TP_SIZE" \
    --arg vllmKey "$VLLM_API_KEY" \
    --arg hfTok "${HF_TOKEN:-}" \
    --arg offload "${OFFLOAD_GB:-}" \
    --argjson vols "$VOL_MOUNT_JSON" \
    '{
      client_id: "me",
      image: $image,
      disk: $disk,
      runtype: "ssh_direc",
      onstart: $onstart,
      env: ({
        "-p 8000:8000": "1",
        "MODEL": $model,
        "MAX_LEN": $maxLen,
        "GPU_UTIL": $gpuUtil,
        "TP_SIZE": $tp,
        "VLLM_API_KEY": $vllmKey
      } + (if $hfTok    != "" then {"HF_TOKEN":    $hfTok}    else {} end)
        + (if $offload  != "" then {"OFFLOAD_GB":  $offload}  else {} end))
    } + (if ($vols | length) > 0 then {volume: $vols} else {} end)')
  R=$(vast PUT "/asks/${OFFER_ID}/" "$CREATE_BODY")
  INSTANCE_ID=$(echo "$R" | jq -r '.new_contract // .id // empty')
  [ -n "$INSTANCE_ID" ] || { echo "FAIL: instance create failed:" >&2; echo "$R" | jq . >&2; exit 1; }
  echo "  ✓ Created: $INSTANCE_ID"
fi

cat > "$STATE_FILE" <<EOF
INSTANCE_ID=$INSTANCE_ID
EOF

# ── 3. Wait for RUNNING + capture public ip/port ─────────────
echo
echo "═ 3/6 [$ROUTE]  Waiting for instance RUNNING"
PUBLIC_IP=""; PUBLIC_PORT=""
for i in $(seq 1 60); do
  R=$(vast GET "/instances/${INSTANCE_ID}/")
  STATUS=$(echo "$R" | jq -r '.instances.actual_status // .actual_status // "loading"')
  printf "  status=%s (poll %d/60)\r" "$STATUS" "$i"
  if [ "$STATUS" = "running" ]; then
    PUBLIC_IP=$(echo "$R" | jq -r '.instances.public_ipaddr // .public_ipaddr // empty')
    # Vast maps each exposed container port to a host port. We exposed 8000.
    PUBLIC_PORT=$(echo "$R" | jq -r '.instances.ports["8000/tcp"][0].HostPort // .ports["8000/tcp"][0].HostPort // empty')
    [ -n "$PUBLIC_IP" ] && [ -n "$PUBLIC_PORT" ] && break
  fi
  sleep 10
done
echo
[ -n "$PUBLIC_IP" ] && [ -n "$PUBLIC_PORT" ] || {
  echo "FAIL: instance did not reach RUNNING with mapped port in 10 min" >&2
  exit 1
}
API_BASE="http://${PUBLIC_IP}:${PUBLIC_PORT}/v1"
echo "  ✓ RUNNING — vLLM target: $API_BASE"

# ── 4. Write env-runtime + bring up LiteLLM ──────────────────
echo
echo "═ 4/6 [$ROUTE]  Writing .env-runtime entry"
{
  flock -x 200
  touch .env-runtime
  # Strip this profile's existing entries + the master-key line, then
  # rewrite all of them. The master key MUST be in .env-runtime so that
  # docker-compose's env_file picks it up on every recreate — otherwise
  # any caller (destroy.sh, parallel deploys) that forgets to export it
  # would create a broken LiteLLM with no auth.
  grep -vE "^(${ROUTE_UPPER}_API_|LITELLM_MASTER_KEY=)" .env-runtime > .env-runtime.tmp || true
  cat >> .env-runtime.tmp <<EOF
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
${ROUTE_UPPER}_API_BASE=${API_BASE}
${ROUTE_UPPER}_API_KEY=${VLLM_API_KEY}
EOF
  mv .env-runtime.tmp .env-runtime

  if ! docker compose ps litellm --status running 2>/dev/null | grep -q litellm; then
    docker compose up -d >/dev/null 2>&1
  else
    docker compose up -d --force-recreate litellm >/dev/null 2>&1
  fi
  sleep 3
} 200>.deploy-lock
echo "  ✓ LiteLLM on http://localhost:4000 with $ROUTE route active"

# ── 5. Wait for vLLM warmup ──────────────────────────────────
echo
echo "═ 5/6 [$ROUTE]  Waiting for vLLM (~10–20 min cold)"
for i in $(seq 1 120); do
  if ./scripts/smoketest.sh "$ROUTE" >/dev/null 2>&1; then
    echo "  ✓ vLLM responding"
    break
  fi
  printf "  warming (poll %d/120, ~%dm elapsed)\r" "$i" "$((i*10/60))"
  sleep 10
done
echo

# ── 6. Final smoke test ──────────────────────────────────────
echo "═ 6/6 [$ROUTE]  Smoke test"
./scripts/smoketest.sh "$ROUTE"

cat <<EOF

═══════════════════════════════════════════════════════════
  [$ROUTE]  Vast.ai deployment complete.

  Cline configuration:
    API Provider: OpenAI Compatible
    Base URL:     http://localhost:4000/v1
    API Key:      $LITELLM_MASTER_KEY
    Model ID:     $ROUTE

  Instance:   $INSTANCE_ID
  Shape:      ${NUM_GPUS}× $GPU_NAME
  vLLM URL:   ${API_BASE} (plain HTTP — bearer-token-only auth)
  Teardown:   ./scripts/destroy.sh $ROUTE
═══════════════════════════════════════════════════════════
EOF
