#!/usr/bin/env bash
# Install zdr-coder prerequisites: Docker, wireguard-tools, jq, openssl, flock,
# VSCodium, and the Cline extension. macOS (Homebrew) or Ubuntu/Debian (apt).
# Windows: see scripts/install-prereqs.ps1.

set -euo pipefail

need_install() { ! command -v "$1" >/dev/null 2>&1; }

# ── macOS via Homebrew ───────────────────────────────────────
install_macos() {
  if need_install brew; then
    echo "FAIL: Homebrew not installed. Get it: https://brew.sh" >&2
    exit 1
  fi

  echo "→ Installing CLI tools (wireguard-tools, jq, flock)..."
  brew install wireguard-tools jq flock

  if need_install docker; then
    echo "→ Installing Docker Desktop..."
    brew install --cask docker
    echo "  ⚠  Open Docker Desktop once to complete setup, then re-run this script."
  fi

  if need_install codium; then
    echo "→ Installing VSCodium..."
    brew install --cask vscodium
  fi

  echo "→ Installing Cline extension..."
  codium --install-extension saoudrizwan.claude-dev >/dev/null 2>&1 || \
    echo "  ⚠  Cline install skipped (run manually if needed)"
}

# ── Ubuntu/Debian via apt ────────────────────────────────────
install_apt() {
  echo "→ Installing CLI tools (docker, wireguard-tools, jq, openssl, flock)..."
  sudo apt-get update -qq
  sudo apt-get install -y docker.io docker-compose-v2 wireguard-tools jq curl openssl util-linux ca-certificates gpg

  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    echo "  ⚠  Added $USER to docker group. Log out and back in for it to take effect."
  fi

  if need_install codium; then
    echo "→ Installing VSCodium..."
    wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
      | gpg --dearmor \
      | sudo dd of=/usr/share/keyrings/vscodium-archive-keyring.gpg status=none
    echo "deb [signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" \
      | sudo tee /etc/apt/sources.list.d/vscodium.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y codium
  fi

  echo "→ Installing Cline extension..."
  codium --install-extension saoudrizwan.claude-dev >/dev/null 2>&1 || \
    echo "  ⚠  Cline install skipped (run manually if needed)"
}

case "$(uname -s)" in
  Darwin)
    install_macos
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      install_apt
    else
      cat >&2 <<EOF
FAIL: Linux without apt-get is unsupported by this auto-installer.
Install manually:
  docker, wireguard-tools, jq, openssl, util-linux (for flock), vscodium
Then run scripts/preflight.sh to verify.
EOF
      exit 1
    fi
    ;;
  *)
    cat >&2 <<EOF
Unsupported OS: $(uname -s)
  macOS / Ubuntu:  ./scripts/install-prereqs.sh
  Windows:         .\scripts\install-prereqs.ps1  (in PowerShell as admin)
EOF
    exit 1
    ;;
esac

cat <<EOF

✓ Prerequisites installed.

Next:
  cp .env.example .env
  \$EDITOR .env                  # set RUNPOD_API_KEY
  ./scripts/deploy.sh sonnet    # or: haiku | opus | all
EOF
