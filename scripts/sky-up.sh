#!/usr/bin/env bash
# Launch one or more SkyPilot configs and update .env-runtime with the
# resulting endpoint URLs so LiteLLM can route to them.
#
# Usage:
#   ./scripts/sky-up.sh haiku-pod
#   ./scripts/sky-up.sh haiku-pod sonnet-pod opus-pod
#   ./scripts/sky-up.sh --all              # haiku-pod + sonnet-pod + opus-pod
#   ./scripts/sky-up.sh --serves           # all 3 serves
#
# After launch, ./scripts/api-up.sh will load .env-runtime and the new model
# IDs (haiku-pod, sonnet-pod, opus-pod, haiku-serve, sonnet-serve, opus-serve)
# become available through LiteLLM at http://localhost:4000.

set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d .venv-sky ]] || { echo "FAIL: SkyPilot venv missing. Run ./scripts/setup.sh first." >&2; exit 1; }
SKY=".venv-sky/bin/sky"

# Parse args
CONFIGS=()
case "${1:-}" in
  --all)     CONFIGS=(haiku-pod sonnet-pod opus-pod) ;;
  --serves)  CONFIGS=(haiku-serve sonnet-serve opus-serve) ;;
  --pods)    CONFIGS=(haiku-pod sonnet-pod opus-pod) ;;
  "")        echo "Usage: $0 <config-name> [<config-name>...] | --all | --pods | --serves"; exit 1 ;;
  *)         CONFIGS=("$@") ;;
esac

# Launch each config in background, capture pid
declare -a PIDS=()
for cfg in "${CONFIGS[@]}"; do
  yaml="sky/${cfg}.yaml"
  [[ -f "$yaml" ]] || { echo "  ⚠️  $yaml not found, skipping"; continue; }
  log="/tmp/sky-up-${cfg}.log"
  echo "→ Launching $cfg (log: $log)"
  if [[ "$cfg" == *-serve ]]; then
    "$SKY" serve up -n "$cfg" "$yaml" --yes > "$log" 2>&1 &
  else
    "$SKY" launch -c "$cfg" "$yaml" --yes --idle-minutes-to-autostop 60 --retry-until-up > "$log" 2>&1 &
  fi
  PIDS+=("$!")
done

echo "Waiting for ${#PIDS[@]} launch(es) to finish..."
for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

# Refresh endpoint URLs in .env-runtime
echo "Refreshing endpoint URLs..."
{
  for cfg in "${CONFIGS[@]}"; do
    var_name="$(echo "${cfg//-/_}" | tr '[:lower:]' '[:upper:]')_API_BASE"
    if [[ "$cfg" == *-serve ]]; then
      ep="$("$SKY" serve status "$cfg" --endpoint 2>/dev/null | tail -1 || true)"
    else
      ep="$("$SKY" status --endpoint 8080 "$cfg" 2>/dev/null | tail -1 || true)"
    fi
    if [[ -n "$ep" && "$ep" != *"not"* && "$ep" != *"error"* ]]; then
      # Strip any color codes / warnings, strip "http://" if present
      ep="${ep#http://}"
      echo "${var_name}=http://${ep}/v1"
      echo "  ✓ ${var_name}=http://${ep}/v1"
    else
      echo "  ⚠️  ${cfg}: endpoint not available (cluster not up?)"
    fi
  done
} > .env-runtime.tmp 2>/dev/null

# Merge into .env-runtime (preserving any existing keys not overwritten)
if [[ -f .env-runtime ]]; then
  comm -23 <(grep -v '^$\|^#' .env-runtime | sort -u) <(grep -oE '^[A-Z_]+=' .env-runtime.tmp | sort -u) > .env-runtime.kept || true
  cat .env-runtime.kept .env-runtime.tmp > .env-runtime
  rm -f .env-runtime.kept
else
  mv .env-runtime.tmp .env-runtime
fi
rm -f .env-runtime.tmp

echo
echo "✓ Done. Endpoint URLs written to .env-runtime"
echo "  Restart LiteLLM to pick up the new routes:"
echo "    ./scripts/api-up.sh"
