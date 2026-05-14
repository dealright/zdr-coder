#!/usr/bin/env bash
# Pre-flight checks before `docker compose up`.
# Validates prereqs and .env values. Idempotent, no state changes.

set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
fail() { echo "✗ $1" >&2; echo "  → $2" >&2; FAIL=1; }
pass() { echo "✓ $1"; }

# 1. Docker installed + daemon up
if ! command -v docker >/dev/null 2>&1; then
  fail "docker not on PATH" "Install Docker Desktop (https://docker.com)"
elif ! docker info >/dev/null 2>&1; then
  fail "docker daemon not running" "Start Docker Desktop"
else
  pass "docker daemon responsive"
fi

# 2. docker compose available
if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose not available" "Update Docker Desktop or install the compose plugin"
else
  pass "docker compose v$(docker compose version --short)"
fi

# 3. openssl available (for generating master key)
if ! command -v openssl >/dev/null 2>&1; then
  fail "openssl not on PATH" "Install via brew install openssl (macOS) or apt install openssl (Linux)"
else
  pass "openssl available"
fi

# 4. .env exists
if [ ! -f .env ]; then
  fail ".env file missing" "Run: cp .env.example .env, then fill in real values"
  echo
  echo "Preflight FAILED. Fix the issues above before running: docker compose up -d" >&2
  exit 1
else
  pass ".env exists"
fi

# Source .env without leaking into shell
set -a
. ./.env
set +a

# 5. LITELLM_MASTER_KEY non-default
if [ -z "${LITELLM_MASTER_KEY:-}" ] || [[ "${LITELLM_MASTER_KEY}" == "sk-replace-with-openssl-rand-hex-32" ]]; then
  fail "LITELLM_MASTER_KEY is unset or placeholder" "Generate one: openssl rand -hex 32 | awk '{print \"sk-\"\$0}'  then paste into .env"
else
  pass "LITELLM_MASTER_KEY set (${LITELLM_MASTER_KEY:0:12}...)"
fi

# 6. TS_AUTHKEY non-default
if [ -z "${TS_AUTHKEY:-}" ] || [[ "${TS_AUTHKEY}" == "tskey-auth-replace-with-real-key" ]]; then
  fail "TS_AUTHKEY is unset or placeholder" "Generate at https://login.tailscale.com/admin/settings/keys (reusable, ephemeral)"
else
  pass "TS_AUTHKEY set (${TS_AUTHKEY:0:16}...)"
fi

# 7. LITELLM_HOSTNAME set
if [ -z "${LITELLM_HOSTNAME:-}" ]; then
  fail "LITELLM_HOSTNAME unset" "Set in .env (e.g. LITELLM_HOSTNAME=litellm-laptop)"
else
  pass "LITELLM_HOSTNAME=${LITELLM_HOSTNAME}"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "Preflight FAILED. Fix the issues above before running: docker compose up -d" >&2
  exit 1
else
  echo "Preflight OK. Next: docker compose up -d"
fi
