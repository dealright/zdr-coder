#!/usr/bin/env bash
# Create a Vast.ai data volume on a specific host and pre-populate it with a
# model's weights from HuggingFace. Subsequent `deploy-vast.sh <profile>` runs
# can mount this volume and skip the multi-hundred-GiB cold download.
#
# Usage:  ./scripts/vol-up.sh <profile>
#   profile = haiku | sonnet | opus
#
# The volume is pinned to a specific machine_id (Vast's model). If that host
# disappears the volume is unavailable — for resilient long-term use prefer
# RunPod network volumes (region-scoped). Vast volumes work fine for short
# project windows (days to weeks).
#
# Workflow:
#   1. Search for the cheapest rentable host matching the profile's GPU shape.
#   2. Create a data volume on that host (size = model weights + 20% buffer).
#   3. Spin up a one-shot pod on that host that mounts the volume and runs
#      huggingface-cli download to populate it.
#   4. Tear the pod down. Volume persists.
#   5. Future deploys check .runpod-state.<profile>-volume and mount it.
#
# Storage cost is billed per-second by Vast at roughly $0.05/GB/month. An
# 800 GB volume for an 8-hour workday costs about $0.30. Deleting at EOD
# stops the charge entirely — see vol-down.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-}"
case "$PROFILE" in haiku|sonnet|opus) ;; *)
  echo "Usage: $0 [haiku|sonnet|opus]" >&2; exit 1 ;;
esac

ROUTE="${PROFILE}-vast"
VOL_STATE=".runpod-state.${ROUTE}-volume"

[ -f .env ] || { echo "FAIL: .env missing." >&2; exit 1; }
set -a; . ./.env; set +a
: "${VAST_API_KEY:?Set VAST_API_KEY in .env}"

vast() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "https://console.vast.ai/api/v0${path}" \
      -H "Authorization: Bearer $VAST_API_KEY" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -X "$method" "https://console.vast.ai/api/v0${path}" \
      -H "Authorization: Bearer $VAST_API_KEY"
  fi
}

# Per-profile sizing — model weights + 20% buffer for HF cache metadata.
case "$PROFILE" in
  haiku)   MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}";   VOL_GB="${VOL_GB:-50}";  GPU_NAME="RTX 4090";     NUM_GPUS=1 ;;
  sonnet)  MODEL="${MODEL:-deepseek-ai/DeepSeek-V4-Flash}";          VOL_GB="${VOL_GB:-200}"; GPU_NAME="A100 SXM4";    NUM_GPUS=4 ;;
  opus)    MODEL="${MODEL:-moonshotai/Kimi-K2.6}";                   VOL_GB="${VOL_GB:-700}"; GPU_NAME="H100 SXM";     NUM_GPUS=8 ;;
esac

if [ -f "$VOL_STATE" ]; then
  echo "FAIL: $VOL_STATE already exists — vol-down first if you want to recreate." >&2
  cat "$VOL_STATE" >&2
  exit 1
fi

# ── 1. Pick a host (uses same filters as deploy-vast.sh but we capture machine_id) ─
echo "═ 1/3 [$ROUTE-volume]  Find host for $NUM_GPUS× $GPU_NAME"
if [ "${VAST_ALLOW_MARKETPLACE:-0}" = "1" ]; then
  TIER='{}'
else
  TIER='"datacenter":{"eq":true},'
fi
SEARCH=$(printf '{%s"rentable":{"eq":true},"gpu_name":{"eq":"%s"},"num_gpus":{"eq":%d},"gpu_ram":{"gte":80000},"disk_space":{"gte":%d},"direct_port_count":{"gte":1},"inet_down":{"gte":500},"cuda_max_good":{"gte":12.4},"type":"on-demand","order":[["dph_total","asc"]],"limit":3}' "$TIER" "$GPU_NAME" "$NUM_GPUS" "$((VOL_GB + 100))")
[ "$PROFILE" = "haiku" ] && SEARCH=$(echo "$SEARCH" | sed 's/"gpu_ram":{"gte":80000}/"gpu_ram":{"gte":23000}/')
R=$(vast POST "/bundles/" "$SEARCH")
MACHINE_ID=$(echo "$R" | jq -r '.offers[0].machine_id // empty')
HOST_PRICE=$(echo "$R" | jq -r '.offers[0].dph_total // empty')
HOST_LOC=$(echo "$R" | jq -r '.offers[0].geolocation // "unknown"')
OFFER_ID=$(echo "$R" | jq -r '.offers[0].id // empty')
[ -n "$MACHINE_ID" ] || { echo "FAIL: no matching host" >&2; exit 1; }
echo "  ✓ Host machine_id=$MACHINE_ID ($HOST_LOC, \$$HOST_PRICE/hr active)"

# ── 2. Create the volume on that host ────────────────────────
echo
echo "═ 2/3 [$ROUTE-volume]  Create ${VOL_GB} GB volume"
BODY=$(jq -nc --arg name "zdr-${ROUTE}-cache" --argjson m "$MACHINE_ID" --argjson size "$VOL_GB" \
  '{name: $name, machine_id: $m, disk: $size}')
R=$(vast POST "/volumes/" "$BODY")
VOL_ID=$(echo "$R" | jq -r '.id // .volume.id // empty')
[ -n "$VOL_ID" ] || { echo "FAIL: volume create:" >&2; echo "$R" | jq . >&2; exit 1; }
echo "  ✓ Volume $VOL_ID"

# ── 3. Spin a one-shot pod on the same host to populate the volume ─
echo
echo "═ 3/3 [$ROUTE-volume]  Populate via one-shot pod"
HF_TOKEN_LINE=""
[ -n "${HF_TOKEN:-}" ] && HF_TOKEN_LINE="HF_TOKEN=$HF_TOKEN"
ONSTART="set -e; pip install -q -U huggingface_hub && export HF_HOME=/workspace/hf-cache && huggingface-cli download '$MODEL' --resume-download --max-workers 8 && echo DONE && sleep 10"
BODY=$(jq -nc \
  --arg image "vllm/vllm-openai:latest" \
  --arg onstart "$ONSTART" \
  --argjson disk 50 \
  --arg model "$MODEL" \
  --arg hfTok "${HF_TOKEN:-}" \
  --argjson vol "$VOL_ID" \
  '{
    client_id: "me", image: $image, disk: $disk,
    onstart: $onstart, runtype: "ssh_direc",
    env: ({MODEL: $model} + (if $hfTok != "" then {HF_TOKEN: $hfTok} else {} end)),
    volume: [{volume_id: $vol, mount_path: "/workspace/hf-cache"}]
  }')
R=$(vast PUT "/asks/${OFFER_ID}/" "$BODY")
POP_ID=$(echo "$R" | jq -r '.new_contract // .id // empty')
[ -n "$POP_ID" ] || { echo "FAIL: populate pod create:" >&2; echo "$R" | jq . >&2; exit 1; }
echo "  ✓ Populate pod $POP_ID running, downloading $MODEL to volume..."
echo "  (this takes 10-90 min depending on model size + host bandwidth)"
echo "  Tail logs: vast logs $POP_ID  — or watch instance in https://cloud.vast.ai/instances/"

# Persist state
cat > "$VOL_STATE" <<EOF
VOLUME_ID=$VOL_ID
MACHINE_ID=$MACHINE_ID
MODEL=$MODEL
VOL_GB=$VOL_GB
POPULATE_INSTANCE=$POP_ID
EOF

cat <<EOF

═════════════════════════════════════════════════════════════
  Volume create kicked off.

  State:        $VOL_STATE
  Volume:       $VOL_ID (${VOL_GB} GB)
  Pinned to:    machine_id=$MACHINE_ID ($HOST_LOC)
  Populating:   pod $POP_ID — running 'huggingface-cli download'

  When DOWNLOAD COMPLETES (check log), the populate pod self-stops.
  Subsequent  ./scripts/deploy-vast.sh $PROFILE  will detect this state
  and mount the populated volume — skipping the model download.

  Tear down at EOD: ./scripts/vol-down.sh $PROFILE
═════════════════════════════════════════════════════════════
EOF
