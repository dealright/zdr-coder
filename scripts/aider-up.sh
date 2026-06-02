#!/usr/bin/env bash
# One-time Aider installation.
#
# Aider is a terminal-based agentic coding tool that pairs cleanly with this
# repo's LiteLLM proxy. Compared to VSCode-extension agents (Cline, Roo, etc.):
# fewer moving parts, no extension-host quirks, works over SSH/tmux without
# tunneling complications, mature git integration.
#
# Run once per machine; afterwards use ./scripts/aider.sh to launch.

set -euo pipefail

if command -v aider >/dev/null 2>&1; then
  echo "✓ aider already installed: $(aider --version 2>/dev/null | head -1)"
  echo "  Next: ./scripts/aider.sh"
  exit 0
fi

echo "═ Installing aider via pipx"

if ! command -v pipx >/dev/null 2>&1; then
  echo "  pipx not found — installing first"
  case "$(uname)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || { echo "FAIL: brew not on PATH. Install Homebrew first." >&2; exit 1; }
      brew install pipx
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y pipx
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y pipx
      else
        echo "FAIL: unknown Linux package manager. Install pipx manually." >&2
        exit 1
      fi
      ;;
    *)
      echo "FAIL: unsupported OS: $(uname). Install pipx + aider manually." >&2
      exit 1
      ;;
  esac
  pipx ensurepath
fi

pipx install aider-chat

# pipx ensurepath modifies shell rc files; current session may not have
# ~/.local/bin on PATH yet. Surface a hint if so.
if ! command -v aider >/dev/null 2>&1; then
  echo
  echo "⚠ aider is installed but not on PATH in this shell. Either:"
  echo "    exec \$SHELL -l        # reload shell"
  echo "  or"
  echo "    ~/.local/bin/aider    # use the absolute path"
fi

echo
echo "✓ aider installed"
echo "  Next: ./scripts/aider.sh"
