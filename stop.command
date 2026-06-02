#!/bin/bash
# Double-click to stop everything. Safe to run anytime.

cd "$(dirname "$0")"

./scripts/openhands-down.sh 2>/dev/null || true
./scripts/destroy.sh api 2>/dev/null || true

echo
echo "Everything stopped. Your API keys in .env are preserved."
read -p "Press Enter to close this window..."
