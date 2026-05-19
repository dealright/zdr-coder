#!/usr/bin/env bash
# Manage SSH RemoteForward for the zdr-coder LiteLLM proxy.
#
# When you use VSCodium + Cline via Remote-SSH (or Tailscale SSH) to a remote
# Linux host but want LiteLLM to keep running on this Mac, add a reverse
# port-forward so the remote sees `localhost:4000` tunneled back here. No
# ACL change, no exposed listener — just rides the SSH session you're already
# opening.
#
# Compared to docker-compose.tailscale.yml: that approach exposes :4000 on
# your Mac's Tailscale interface (requires your tailnet ACL to permit the
# remote → Mac direction). This SSH-tunnel approach works regardless of ACL
# because it piggybacks the existing forward direction.
#
# Usage:
#   ./scripts/tunnel.sh init <ssh-host>     # add RemoteForward to ~/.ssh/config
#   ./scripts/tunnel.sh deinit <ssh-host>   # remove the block
#   ./scripts/tunnel.sh status              # list currently configured hosts

set -euo pipefail

CMD="${1:-}"
HOST="${2:-}"
PORT="${LITELLM_PORT:-4000}"
CONFIG="${HOME}/.ssh/config"
MARK_BEGIN="# BEGIN zdr-coder tunnel"
MARK_END="# END zdr-coder tunnel"

usage() {
  cat <<EOF
Usage:
  $0 init <ssh-host>     Add RemoteForward $PORT for <ssh-host> in ~/.ssh/config
  $0 deinit <ssh-host>   Remove the zdr-coder block for <ssh-host>
  $0 status              List zdr-coder-managed host blocks

After 'init', reconnect any open ssh/VSCodium-Remote-SSH session to <ssh-host>
so the new RemoteForward takes effect. Then on the remote, Cline can use:
  Base URL:  http://localhost:$PORT/v1
EOF
}

strip_block() {
  # Remove existing zdr-coder block for $HOST (idempotent)
  awk -v begin="$MARK_BEGIN: $HOST" -v end="$MARK_END: $HOST" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip { print }
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

case "$CMD" in
  init)
    [ -n "$HOST" ] || { usage >&2; exit 1; }
    mkdir -p "$(dirname "$CONFIG")"
    touch "$CONFIG"
    chmod 600 "$CONFIG"

    strip_block

    cat >> "$CONFIG" <<EOF

$MARK_BEGIN: $HOST
Host $HOST
  RemoteForward $PORT 127.0.0.1:$PORT
$MARK_END: $HOST
EOF
    echo "✓ Added RemoteForward $PORT → 127.0.0.1:$PORT for '$HOST' in $CONFIG"
    echo
    echo "Next steps:"
    echo "  1. Reconnect any open ssh / VSCodium Remote-SSH session to $HOST"
    echo "     (close the Remote-SSH window in VSCodium → reopen)"
    echo "  2. Verify the tunnel from this Mac:"
    echo "       ssh $HOST \"curl -sS http://localhost:$PORT/v1/models \\\\"
    echo "         -H 'Authorization: Bearer \$(cat .litellm-key)' | head -c 80\""
    echo "  3. In Cline on $HOST: Base URL = http://localhost:$PORT/v1 (unchanged)"
    ;;

  deinit)
    [ -n "$HOST" ] || { usage >&2; exit 1; }
    [ -f "$CONFIG" ] || { echo "No $CONFIG — nothing to remove"; exit 0; }
    if ! grep -q "^$MARK_BEGIN: $HOST\$" "$CONFIG"; then
      echo "No zdr-coder tunnel block for '$HOST' found in $CONFIG — nothing to do"
      exit 0
    fi
    strip_block
    echo "✓ Removed zdr-coder tunnel block for '$HOST' from $CONFIG"
    echo "  (existing ssh sessions keep their forwarded ports until they exit)"
    ;;

  status)
    if [ ! -f "$CONFIG" ]; then
      echo "(no ~/.ssh/config)"
      exit 0
    fi
    if ! grep -q "^$MARK_BEGIN" "$CONFIG" 2>/dev/null; then
      echo "No zdr-coder tunnels configured"
    else
      echo "Configured zdr-coder tunnels:"
      grep "^$MARK_BEGIN" "$CONFIG" | sed "s|^$MARK_BEGIN: |  • |"
    fi
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
