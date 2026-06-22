#!/usr/bin/env bash
# Install a systemd unit so the zdr-coder LiteLLM proxy auto-starts on boot.
# Linux + systemd only. Idempotent — re-run any time (e.g. after `git pull`).
#
# Why a unit at all when the container already has `restart: unless-stopped`?
# Boot ordering. On a cold boot dockerd can start BEFORE tailscaled has assigned
# the tailnet IP, so binding 100.x.y.z:4000 (the docker-compose.tailscale.yml
# override) fails and the container crash-loops until Tailscale is up. This unit
# waits for Tailscale, then brings the stack up bound to the tailnet. If
# Tailscale isn't installed it binds loopback only. The container's own
# restart policy still handles mid-run crashes.
#
# Usage:
#   sudo ./scripts/install-service.sh              # install, enable, start
#   sudo ./scripts/install-service.sh --uninstall  # remove the unit
#   systemctl status zdr-coder                     # check it
#   journalctl -u zdr-coder                        # boot logs
#
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
UNIT=/etc/systemd/system/zdr-coder.service
# The service runs as root, and docker-compose.yml mounts ${HOME}/.aws into the
# container for Bedrock creds. systemd does NOT set HOME for root services — it's
# empty, so ${HOME}/.aws resolves to /.aws and Bedrock 401s. Pin HOME to root's
# home so the mount points at the real creds.
SVC_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"; SVC_HOME="${SVC_HOME:-/root}"

[ "$(uname -s)" = Linux ]       || { echo "FAIL: Linux/systemd only (host is $(uname -s)). On macOS, Docker Desktop + the container's restart:unless-stopped already restores it on login." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "FAIL: systemctl not found (no systemd)." >&2; exit 1; }
[ "$(id -u)" = 0 ]              || { echo "FAIL: run as root: sudo $0 ${*:-}" >&2; exit 1; }

if [ "${1:-}" = --uninstall ]; then
  systemctl disable --now zdr-coder.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  echo "✓ Removed zdr-coder.service. (Containers left as-is; run 'docker compose down' to stop them.)"
  exit 0
fi

command -v docker >/dev/null || { echo "FAIL: docker not installed." >&2; exit 1; }

[ -f "${SVC_HOME}/.aws/credentials" ] || echo "⚠️  ${SVC_HOME}/.aws/credentials not found — Bedrock routes (opus-claude, opus-glm, …) will 401 until it's present."

cat > "$UNIT" <<'UNIT_EOF'
[Unit]
Description=zdr-coder — local LiteLLM proxy (auto-start; tailnet-bound when Tailscale present)
Documentation=https://github.com/dealright/zdr-coder
Requires=docker.service
After=docker.service tailscaled.service network-online.target
Wants=tailscaled.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=__REPO_DIR__
# Pin HOME so docker-compose's ${HOME}/.aws mount finds the Bedrock creds
# (systemd leaves HOME empty for root services -> would mount /.aws -> 401).
Environment=HOME=__SVC_HOME__
TimeoutStartSec=180
# Wait up to 60s for Tailscale to assign an IP (so the tailnet port-bind doesn't
# fail when dockerd races ahead of tailscaled on a cold boot), then bring the
# stack up bound to it. Falls back to loopback-only if Tailscale isn't present.
ExecStart=/usr/bin/env bash -c 'ip=""; if command -v tailscale >/dev/null 2>&1; then for i in $(seq 1 30); do ip=$(tailscale ip -4 2>/dev/null | head -1); [ -n "$ip" ] && break; sleep 2; done; fi; if [ -n "$ip" ]; then echo "tailnet bind: $ip"; TAILSCALE_IP="$ip" docker compose -f docker-compose.yml -f docker-compose.tailscale.yml up -d; else echo "loopback bind only"; docker compose up -d; fi'
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT_EOF

sed -i -e "s#__REPO_DIR__#${REPO_DIR}#" -e "s#__SVC_HOME__#${SVC_HOME}#" "$UNIT"

systemctl daemon-reload
systemctl enable zdr-coder.service
systemctl restart zdr-coder.service
echo "✓ zdr-coder.service installed + enabled (starts on boot), and (re)started now."
echo "  WorkingDirectory: ${REPO_DIR}"
echo
systemctl --no-pager --full status zdr-coder.service 2>&1 | head -10
