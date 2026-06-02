#!/bin/bash
# Double-click launcher for macOS. Brings up the whole stack (LiteLLM proxy
# + OpenHands web UI) and opens it in your default browser.
#
# Prereqs (one-time):
#   - Docker Desktop installed and running
#   - .env file in this folder with GROQ_API_KEY set
#
# Just double-click this file in Finder.

cd "$(dirname "$0")"

# Make sure Docker Desktop is running
if ! docker info >/dev/null 2>&1; then
  osascript -e 'tell application "Docker Desktop" to launch' 2>/dev/null
  echo "Waiting for Docker Desktop to start..."
  for i in {1..60}; do
    if docker info >/dev/null 2>&1; then break; fi
    sleep 2
  done
  if ! docker info >/dev/null 2>&1; then
    osascript -e 'display dialog "Docker Desktop did not start. Install it from https://docs.docker.com/desktop/install/mac-install/ and try again." buttons {"OK"} default button "OK" with icon stop'
    exit 1
  fi
fi

# Ensure .env exists with GROQ_API_KEY
if [ ! -f .env ] || ! grep -q '^GROQ_API_KEY=.\+' .env; then
  osascript -e 'display dialog "Missing Groq API key. Open the .env file, paste your key from console.groq.com on the GROQ_API_KEY= line, save, and try again." buttons {"Open .env"} default button "Open .env" with icon caution'
  open -t .env 2>/dev/null || open .env
  exit 1
fi

./scripts/api-up.sh && ./scripts/openhands-up.sh

# Open the OpenHands web UI in default browser
open http://localhost:3000

# Keep the Terminal window open so the user sees what happened
echo
echo "Stack is running. Close this Terminal window to leave it running in the background."
echo "To stop everything: double-click stop.command in this folder."
echo
read -p "Press Enter to close this window..."
