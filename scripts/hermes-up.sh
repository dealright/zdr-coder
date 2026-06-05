#!/usr/bin/env bash
# Bring up Nous Hermes Agent wired to your local LiteLLM proxy, with manual
# command approval enabled — every shell command flagged by Hermes' dangerous-
# pattern detector pauses for [o]nce / [s]ession / [a]lways / [d]eny before
# executing. Use for sysadmin tasks where blast radius matters.
#
# Compared to OpenHands:
#  - Hermes has 40+ built-in tools (web search, deep research, browser, cron,
#    image gen, TTS, shell across multiple backends) where OpenHands has ~5.
#  - Hermes is TUI + messaging-gateway (Telegram, Discord, Signal, Email).
#  - Hermes' approval model is dangerous-pattern-detection, not per-tool.
#
# Compared to YOLO mode (hermes --yolo):
#  - This script does NOT enable YOLO. Every rm -r, chmod 777, dd if=, mkfs,
#    sudo, curl|sh, > /etc/, kill -9, systemctl stop pauses for confirmation.
#  - Hardline blocklist (always-denied, no override): rm -rf /, fork bombs,
#    mkfs on mounted root, dd to /dev/sd*.
#
# Requires: ./scripts/api-up.sh already run (so LiteLLM is on :4000).
#
# Usage:
#   ./scripts/hermes-up.sh                              # default model: haiku-api
#   HERMES_MODEL=sonnet-api ./scripts/hermes-up.sh      # different tier
#   HERMES_MODEL=haiku-pod ./scripts/hermes-up.sh       # self-hosted GPU
#
# After setup, launch the TUI with: hermes

set -euo pipefail
cd "$(dirname "$0")/.."

# ─── prereqs ────────────────────────────────────────────────────────────────

if [[ ! -f .litellm-key ]]; then
  echo "FAIL: LiteLLM not deployed. Run ./scripts/api-up.sh first." >&2
  exit 1
fi

# Verify LiteLLM is responding
LITELLM_KEY="$(cat .litellm-key)"
HTTP="$(curl -sS -m 3 -o /dev/null -w "%{http_code}" \
  "http://localhost:4000/health/readiness" 2>/dev/null || echo 000)"
if [[ "$HTTP" != "200" ]]; then
  echo "FAIL: LiteLLM at http://localhost:4000 returned HTTP $HTTP." >&2
  echo "      Run ./scripts/api-up.sh and retry." >&2
  exit 1
fi

# ─── install Hermes if missing ──────────────────────────────────────────────

if ! command -v hermes >/dev/null 2>&1; then
  echo "Hermes not found. Installing from https://hermes-agent.nousresearch.com ..."
  if [[ "$(uname -s)" == "Darwin" || "$(uname -s)" == "Linux" ]]; then
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    # Reload PATH in case installer added a new dir
    if [[ -d "$HOME/.hermes/bin" ]]; then
      export PATH="$HOME/.hermes/bin:$PATH"
    fi
    if ! command -v hermes >/dev/null 2>&1; then
      echo "FAIL: installer ran but 'hermes' still not on PATH." >&2
      echo "      Try: exec -l \$SHELL  then re-run this script." >&2
      exit 1
    fi
  else
    echo "FAIL: this script only handles macOS/Linux install." >&2
    echo "      For Windows, follow https://hermes-agent.nousresearch.com/docs ." >&2
    exit 1
  fi
fi

# ─── write config.yaml ──────────────────────────────────────────────────────

MODEL="${HERMES_MODEL:-haiku-api}"
HERMES_CONFIG_DIR="$HOME/.hermes"
HERMES_CONFIG_FILE="$HERMES_CONFIG_DIR/config.yaml"
mkdir -p "$HERMES_CONFIG_DIR"

# If user already has a config, back it up before overwriting
if [[ -f "$HERMES_CONFIG_FILE" ]] && ! grep -q "managed-by: zdr-coder" "$HERMES_CONFIG_FILE" 2>/dev/null; then
  BACKUP="$HERMES_CONFIG_FILE.backup-$(date +%s)"
  cp "$HERMES_CONFIG_FILE" "$BACKUP"
  echo "Backed up existing config to $BACKUP"
fi

cat > "$HERMES_CONFIG_FILE" <<EOF
# managed-by: zdr-coder
#
# Hermes Agent config — wired to the local LiteLLM proxy (http://localhost:4000)
# so every model call inherits this repo's ZDR posture (Groq SOC2/ISO27001,
# or self-hosted pods on rented GPU).
#
# Safety: approvals.mode: manual — Hermes pauses for confirmation on any of
# the ~50 dangerous shell command patterns (rm -r, chmod 777, dd if=, mkfs,
# sudo, curl|sh, > /etc/, kill -9, systemctl stop, etc.) AND a hardline
# blocklist (rm -rf /, fork bombs, mkfs on mounted root, dd to /dev/sd*).
# To disable approvals temporarily for a single run, use: hermes --yolo
# (NOT recommended on production servers.)

# ── Main LLM ──────────────────────────────────────────────────────────────
# Field name is 'default' (not 'name') per Hermes' provider docs. Malformed
# field names trigger the first-run setup wizard.
model:
  default: $MODEL                       # one of the model IDs from litellm/config.yaml
  provider: custom                      # 'custom' = arbitrary OpenAI-compatible endpoint
  base_url: http://localhost:4000/v1    # local LiteLLM proxy
  api_key: $LITELLM_KEY                 # rotates with .litellm-key
  context_length: 131000                # Hermes requires ≥64K; Groq GPT-OSS supports 131K
                                        # Override per-model in litellm/config.yaml if any route
                                        # serves less than 64K (e.g. haiku-pod at 8K — won't work
                                        # with Hermes at its current vLLM --max-model-len)

# ── Auxiliary models (vision / web summarization / MoA) ───────────────────
# Hermes' default is 'auto' which routes auxiliary work to the main chat
# model — we just keep that default. To split (e.g. cheap haiku-api for
# scraping while main model is opus-pod), uncomment and customize below.
# auxiliary:
#   scraper:
#     provider: custom
#     default: haiku-api
#     base_url: http://localhost:4000/v1
#     api_key: $LITELLM_KEY

# ── Approval gates (the whole point) ──────────────────────────────────────
approvals:
  mode: manual                          # manual | smart | off  — 'manual' = ask every time
  timeout: 300                          # seconds to wait for human reply (default 60)
  # Hermes' built-in dangerous-pattern detector covers ~50 patterns including:
  # rm -r / rm --recursive, chmod 777/666, mkfs, dd if=, DROP TABLE, > /etc/,
  # systemctl stop/restart, kill -9 -1, curl | sh, tee to /etc/.
  # The hardline blocklist (no-override) covers rm -rf /, fork bombs,
  # mkfs on mounted root, dd to /dev/sd*.
EOF

chmod 600 "$HERMES_CONFIG_FILE"

# ─── friendly banner ────────────────────────────────────────────────────────

cat <<EOF

═══════════════════════════════════════════════════════════════════════════
  Hermes Agent configured.

  Config written:    $HERMES_CONFIG_FILE
  LLM model:         $MODEL  (routes through localhost:4000 → LiteLLM)
  Approval mode:     manual  — every dangerous shell pattern pauses for [y/n]
  Approval timeout:  300s

  Launch:            hermes chat                # skips the setup wizard
                     (NOT 'hermes' alone — that triggers the first-run
                      setup wizard which would overwrite this config)

  Approval UX in the TUI:
    proposed: rm -rf /var/log/old-*
    [o]nce — run this one
    [s]ession — auto-approve same command this session
    [a]lways — auto-approve permanently (stored in approvals.allowlist)
    [d]eny — block this and report back to the model

  When to use Hermes vs OpenHands:
    Hermes:    sysadmin / SSH / web search / scheduled tasks / multi-platform
    OpenHands: repo-aware coding work, embedded VSCode, /workspace mount

  Switch model mid-session inside the TUI:  /model haiku-pod  (or any
  model ID from litellm/config.yaml).

  To disable approvals for a single run (NOT for prod): hermes --yolo

  Stop:              just exit the TUI (Ctrl+D or :q)
═══════════════════════════════════════════════════════════════════════════
EOF
