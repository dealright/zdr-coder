#!/usr/bin/env bash
# Pre-flight checks before `docker compose up`.
# Validates prereqs and .env values. Idempotent, no state changes.

set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
fail() { echo "✗ $1" >&2; echo "  → $2" >&2; FAIL=1; }
pass() { echo "✓ $1"; }

if ! command -v docker >/dev/null 2>&1; then
  fail "docker not on PATH" "Install Docker Desktop (https://docker.com)"
elif ! docker info >/dev/null 2>&1; then
  fail "docker daemon not running" "Start Docker Desktop"
else
  pass "docker daemon responsive"
fi

if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose not available" "Update Docker Desktop or install the compose plugin"
else
  pass "docker compose v$(docker compose version --short)"
fi

if ! command -v openssl >/dev/null 2>&1; then
  fail "openssl not on PATH" "brew install openssl (macOS) / apt install openssl (Linux)"
else
  pass "openssl available"
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not on PATH" "brew install jq (macOS) / apt install jq (Linux)"
else
  pass "jq available"
fi

if [ ! -f .env ]; then
  fail ".env file missing" "cp .env.example .env, then set RUNPOD_API_KEY"
  echo
  echo "Preflight FAILED. Fix issues above." >&2
  exit 1
else
  pass ".env exists"
fi

set -a
. ./.env
set +a

if [ -z "${RUNPOD_API_KEY:-}" ] || [[ "$RUNPOD_API_KEY" == "runpod_replace_with_real_key" ]]; then
  fail "RUNPOD_API_KEY is unset or placeholder" "Get one at https://console.runpod.io/user/settings"
else
  pass "RUNPOD_API_KEY set (${RUNPOD_API_KEY:0:14}...)"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "Preflight FAILED." >&2; exit 1
else
  echo "Preflight OK. Run: ./scripts/deploy.sh haiku  (or: sonnet / opus / all)"
fi
