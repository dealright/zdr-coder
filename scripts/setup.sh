#!/usr/bin/env bash
# zdr-coder unified setup script.
#
# Reads ZDR_TIER from .env (default: soc2) and walks you through the minimum
# set of cloud signups + key paste for that tier. Idempotent — skip steps for
# backends that are already configured.
#
# Usage:  ./scripts/setup.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ─────────────────────────── helpers ───────────────────────────

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
hr()     { printf "\033[2m─────────────────────────────────────────────────────────────\033[0m\n"; }

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Returns 0 (continue) if user wants to set up this backend, 1 (skip) otherwise.
# Default is Y (configure). Pressing N just skips for this run — re-run setup.sh
# anytime to add it later.
ask_setup() {
  local name="$1"
  read -r -p "Set up $name now? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    yellow "  ↷ Skipping $name (re-run ./scripts/setup.sh anytime to add it)"
    return 1
  fi
  return 0
}

prompt_secret() {
  local var="$1" label="$2"
  local val
  read -rsp "$label: " val
  echo
  eval "$var=\$val"
}

open_url() {
  if command -v open >/dev/null 2>&1; then open "$1" 2>/dev/null || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" 2>/dev/null || true
  fi
  echo "  → $1"
}

ensure_tool() {
  local tool="$1" install_hint="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    red "Missing required tool: $tool"
    echo "  Install: $install_hint"
    if confirm "Install now?"; then
      eval "$install_hint"
    else
      exit 1
    fi
  fi
}

upsert_env_var() {
  local key="$1" value="$2"
  local env_file=".env"
  [[ -f "$env_file" ]] || cp .env.example "$env_file"
  if grep -q "^${key}=" "$env_file"; then
    # macOS sed needs backup arg
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$env_file" && rm -f "${env_file}.bak"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

read_env_var() {
  local key="$1"
  [[ -f .env ]] || return 1
  grep "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}

# ───────────────────────── prereq check ─────────────────────────

bold "🔧 Checking prereqs"
ensure_tool curl "brew install curl"
ensure_tool jq "brew install jq"

# Venv check
if [[ ! -d .venv-sky ]]; then
  yellow "SkyPilot venv missing. Creating at .venv-sky/"
  ensure_tool python3.12 "brew install python@3.12"
  python3.12 -m venv .venv-sky
  .venv-sky/bin/pip install --quiet --upgrade pip
  .venv-sky/bin/pip install --quiet "skypilot[nebius,verda]" "runpod>=1.6.1"
fi
SKY=".venv-sky/bin/sky"

# ──────────────── 🌟 provider recommendations ─────────────────

hr
bold "💡 Provider recommendations — read this first"
echo
echo "For 95% of users, ONE backend covers nearly everything:"
echo
green "  ⭐ AWS Bedrock — the recommended primary"
echo "     • Simplicity:  one credential (your AWS access key) unlocks ~7 models —"
echo "                    DeepSeek V3.2, Mistral Large 3, Qwen3-Coder, Qwen3-VL,"
echo "                    GLM 4.7 Flash, GLM 5, Claude Opus 4.6"
echo "     • Compliance:  HIPAA BAA self-serve, SOC2 T1+T2, ISO 27001, FedRAMP High,"
echo "                    PCI DSS, GDPR — ZDR is DEFAULT-ON, can't even be disabled"
echo "     • Pricing:     pay-per-token, \$0 idle, no minimums, ~\$0.07–\$8 per M tokens"
echo "                    depending on model. Cheapest sonnet-tier you can get w/ BAA."
echo "     • Audit logs:  native CloudWatch invocation logging (one-line enable later)"
echo
yellow "     ⚠️  THE ONLY DOWNSIDE: SMS verification required for AWS account creation."
yellow "         If you already have an AWS account, you're past this step."
echo
echo "Other providers are optional additions, not replacements:"
echo
echo "  • Groq         — Fastest + cheapest sonnet (\$0.11/\$0.34/M, no SMS, no card)."
echo "                   BAA on request only — NOT HIPAA-by-default. Single-turn workloads."
echo "  • Z.ai direct  — GLM 5.2 (744B MoE, 1M context, latest model). NOT HIPAA —"
echo "                   routes through Chinese infrastructure. Non-PHI experiments only."
echo "  • RunPod/Vast  — self-hosted GPU pods. Full data sovereignty, but ops overhead +"
echo "                   \$2–\$30/hr active. Skip unless you specifically need self-host."
echo "  • Lambda Labs  — same shape as RunPod/Vast. Cheapest A100 SKU in our testing."
echo "  • HuggingFace  — for gated models (Llama 3.3 70B, etc.). Free tier, no SMS."
echo
green "  New here and just want it to work?"
echo "    → Stick with ZDR_TIER=soc2 or =hipaa, set up AWS only, skip the rest."
echo "    → You can re-run ./scripts/setup.sh anytime to add more providers."
echo
hr
echo "Press Enter to continue (or Ctrl+C to edit ZDR_TIER in .env first)..."
read -r _

# ─────────────────────── determine tier ────────────────────────

[[ -f .env ]] || cp .env.example .env
ZDR_TIER="$(read_env_var ZDR_TIER || echo soc2)"
ZDR_TIER="${ZDR_TIER:-soc2}"

hr
bold "📋 Active tier: ZDR_TIER=${ZDR_TIER}"
case "$ZDR_TIER" in
  cheap)
    BACKENDS=(vast runpod r2)
    echo "Configuring: Vast.ai (marketplace) + RunPod (web) + R2 (optional)"
    ;;
  soc2)
    # Top-5-by-fleet sales-free SkyPilot-native backends, minus blockers:
    # - Verda dropped: no open_ports for vLLM endpoint
    # - Nebius dropped: US-card-decline issue, plus card was required for signup
    # - CoreWeave dropped: K8s-only via CKS (not SkyPilot-native)
    # Result: AWS + OCI + Lambda + RunPod + Vast (5-backend coverage)
    BACKENDS=(runpod vast lambda aws oci r2)
    echo "Configuring: RunPod + Vast (instant) + Lambda + AWS + OCI (quota approval) + R2"
    ;;
  hipaa)
    # AWS + OCI both have self-serve / EY-attested HIPAA programs.
    # AWS is click-through BAA; OCI is account-team-attested.
    # RunPod Secure adds a sales-gated BAA option at lower cost.
    BACKENDS=(aws oci runpod r2)
    echo "Configuring: AWS (self-serve BAA) + OCI (FedRAMP High) + RunPod Secure (sales BAA) + R2"
    ;;
  fedramp)
    BACKENDS=(aws azure gcp oci r2)
    echo "Configuring: AWS + Azure + GCP + OCI (all FedRAMP High) + R2 (optional)"
    ;;
  *)
    red "Unknown ZDR_TIER: $ZDR_TIER"
    echo "Set ZDR_TIER to one of: cheap, soc2, hipaa, fedramp in .env"
    exit 1
    ;;
esac

# ────────────────────── per-backend setup ──────────────────────

setup_verda() {
  hr
  bold "🟩 Verda (formerly DataCrunch) — SOC2 Type II + ISO 27001/17/18/701"


  if [[ -f "$HOME/.verda/config.json" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Verda" || return 0

  echo "Sign-up flow:"
  echo "  1. Sign up at https://console.verda.com"
  echo "  2. Dashboard → your project → Keys → Create new API key"
  echo "     URL pattern: https://console.verda.com/dashboard/projects/<your-project-id>/keys"
  echo "  3. Copy Client ID and Client Secret (secret is one-time view — save now)"
  open_url "https://console.verda.com/dashboard"
  echo
  read -rp "Press Enter when you have both values ready..." _

  read -rp "Paste Verda Client ID: " VERDA_ID
  prompt_secret VERDA_SECRET "Paste Verda Client Secret (hidden)"
  read -rp "Default region [FIN-03]: " VERDA_REGION
  VERDA_REGION="${VERDA_REGION:-FIN-03}"

  mkdir -p "$HOME/.verda"
  cat > "$HOME/.verda/config.json" <<EOF
{
  "client_id": "$VERDA_ID",
  "client_secret": "$VERDA_SECRET",
  "base_url": "https://api.verda.com/v1",
  "default_region": "$VERDA_REGION"
}
EOF
  chmod 600 "$HOME/.verda/config.json"
  green "  ✓ Wrote ~/.verda/config.json"
}

setup_runpod() {
  hr
  bold "🟧 RunPod — Secure Cloud only (SkyPilot catalog ships _SECURE SKUs)"


  if [[ -n "$(read_env_var RUNPOD_API_KEY)" ]] && [[ -f "$HOME/.runpod/config.toml" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "RunPod" || return 0

  echo "Sign-up flow:"
  echo "  1. Sign up at https://www.runpod.io if you haven't"
  echo "  2. Settings → API Keys → Create"
  echo "  3. CHOOSE 'All' SCOPE (not Restricted — Restricted breaks /openai/v1)"
  open_url "https://console.runpod.io/user/settings"
  echo
  read -rp "Press Enter when you have the key ready..." _

  prompt_secret RUNPOD_KEY "Paste RunPod API key (hidden)"
  upsert_env_var RUNPOD_API_KEY "$RUNPOD_KEY"
  green "  ✓ Wrote RUNPOD_API_KEY to .env"

  # SkyPilot reads from ~/.runpod/config.toml, not env var — write both
  mkdir -p "$HOME/.runpod"
  cat > "$HOME/.runpod/config.toml" <<EOF
[default]
api_key = "$RUNPOD_KEY"
EOF
  chmod 600 "$HOME/.runpod/config.toml"
  green "  ✓ Wrote ~/.runpod/config.toml"
}

setup_nebius() {
  hr
  bold "🟦 Nebius — SOC2 Type II (HIPAA in scope) + ISO 27001/17/18/701"
  yellow "  Note: Nebius signup may decline US-issued cards. If yours fails, press 'n' to skip."


  if [[ -f "$HOME/.nebius/NEBIUS_IAM_TOKEN.txt" ]] && [[ -f "$HOME/.nebius/NEBIUS_TENANT_ID.txt" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Nebius" || return 0

  # Install CLI if missing
  if ! command -v nebius >/dev/null 2>&1; then
    yellow "Installing Nebius CLI..."
    curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
    # Don't exec -l $SHELL here — try to source the new PATH
    if [[ -f "$HOME/.bashrc" ]]; then source "$HOME/.bashrc" 2>/dev/null || true; fi
    if [[ -f "$HOME/.zshrc" ]]; then source "$HOME/.zshrc" 2>/dev/null || true; fi
    # Add to PATH manually in case shell rc doesn't pick it up in this session
    export PATH="$HOME/.nebius/bin:$PATH"
    if ! command -v nebius >/dev/null 2>&1; then
      red "Nebius CLI installed but not on PATH. Run 'exec -l \$SHELL' then re-run this script."
      exit 1
    fi
  fi

  echo "Sign-up flow:"
  echo "  1. Go to https://nebius.com and click 'Log in to AI Cloud'"
  echo "  2. Create an account (or sign in) and complete onboarding in the browser"
  open_url "https://nebius.com"
  echo
  read -rp "Press Enter when your Nebius account is ready..." _

  echo "Authenticating CLI (opens a browser tab)..."
  nebius profile create

  mkdir -p "$HOME/.nebius"
  nebius iam get-access-token > "$HOME/.nebius/NEBIUS_IAM_TOKEN.txt"
  nebius iam tenant list --format json | jq -r '.items[0].metadata.id' > "$HOME/.nebius/NEBIUS_TENANT_ID.txt"

  green "  ✓ Wrote ~/.nebius/NEBIUS_IAM_TOKEN.txt"
  green "  ✓ Wrote ~/.nebius/NEBIUS_TENANT_ID.txt (tenant: $(cat $HOME/.nebius/NEBIUS_TENANT_ID.txt))"
}

setup_vast() {
  hr
  bold "🟪 Vast.ai — marketplace"


  if [[ -n "$(read_env_var VAST_API_KEY)" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Vast.ai" || return 0

  echo "Sign-up flow:"
  echo "  1. Sign up at https://cloud.vast.ai"
  echo "  2. Account → API Keys → Create (Permissions: Instances RW, 2FA off)"
  open_url "https://cloud.vast.ai/account/"
  echo
  read -rp "Press Enter when you have the key ready..." _

  prompt_secret VAST_KEY "Paste Vast.ai API key (hidden)"
  upsert_env_var VAST_API_KEY "$VAST_KEY"
  green "  ✓ Wrote VAST_API_KEY to .env"
}

setup_aws() {
  hr
  bold "🟫 AWS — hyperscaler (BAA self-serve + FedRAMP High)"
  yellow "  Note: AWS BAA is instant (click-through). GPU quotas are NOT — default = 0,"
  yellow "  approval takes 1-4 days via web form. The flow below tells you exactly where."


  if [[ -f "$HOME/.aws/credentials" ]] && ! confirm "AWS already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    yellow "  Reminder: confirm GPU quotas are non-zero before launching sonnet/opus tiers."
    echo "    aws service-quotas list-service-quotas --service-code ec2 \\"
    echo "      --query 'Quotas[?contains(QuotaName, \`P5\`)].[QuotaName,Value]' --output table"
    return
  fi

  ask_setup "AWS" || return 0

  ensure_tool aws "brew install awscli"

  echo "═══ STEP 1: Account + BAA (5 min, instant) ═══"
  echo "  1. Sign up: https://aws.amazon.com (skip if you have an account)"
  yellow "       ⚠️  New AWS accounts require SMS verification (phone)."
  yellow "       This is the only SMS gate in the whole zdr-coder setup."
  yellow "       If you already have an AWS account, you've already done this."
  echo "  2. BAA (HIPAA): https://us-east-1.console.aws.amazon.com/artifact/"
  echo "       Artifact → Agreements → AWS Business Associate Addendum → Accept"
  echo "       (instant click-through; no waiting; no sales contact)"
  open_url "https://us-east-1.console.aws.amazon.com/artifact/"
  echo
  read -rp "Press Enter when BAA is accepted (or skipped if you don't need HIPAA)..." _

  echo "═══ STEP 2: IAM user + access key for SkyPilot (~5 min) ═══"
  echo "  AWS Management Console (browser) is REQUIRED for this step — there's"
  echo "  no fully-CLI path for first-time IAM user + access key creation."
  echo
  echo "  Open: https://console.aws.amazon.com/iam/home#/users"
  open_url "https://console.aws.amazon.com/iam/home#/users"
  echo
  echo "  ── Screen 1: User details ──────────────────────────────────"
  echo "    User name:              zdr-coder"
  echo "    Console access:         DISABLE (uncheck the box)"
  echo "                            — this is a programmatic/API user only,"
  echo "                              you log into the console as your root/admin"
  echo
  echo "  ── Screen 2: Permissions ──────────────────────────────────"
  echo "    Pick: 'Attach policies directly'"
  echo "    Then in the filter/search box, find and check each:"
  echo
  echo "    REQUIRED (SkyPilot needs all 3):"
  echo "      ✅ AmazonEC2FullAccess     — provision/manage GPU VMs"
  echo "      ✅ AmazonS3FullAccess      — file mounts, bucket-mount cache"
  echo "      ✅ IAMFullAccess           — iam:PassRole for instance roles"
  echo
  echo "    HIGHLY RECOMMENDED (for managed Anthropic Claude via Bedrock):"
  echo "      ✅ AmazonBedrockFullAccess — enables 'bedrock-opus' etc model IDs"
  echo "                                   in LiteLLM as BAA-eligible fallback"
  echo "                                   (inherits AWS HIPAA, SOC 2, FedRAMP,"
  echo "                                   HITRUST — strongest compliance posture"
  echo "                                   of any managed LLM option)"
  echo
  echo "    OPTIONAL (silences a verification warning at end of this script):"
  echo "      ✅ ServiceQuotasReadOnlyAccess — lets sky check verify GPU quotas"
  echo "                                       without AccessDeniedException"
  echo
  echo "  ── Screen 3: Tags ─────────────────────────────────────────"
  echo "    Skip, or add: Project=zdr-coder"
  echo
  echo "  ── Screen 4: Review and Create ────────────────────────────"
  echo "    Click 'Create user'"
  echo
  echo "  ── Screen 5: GENERATE ACCESS KEY (separate, easy to miss) ─"
  echo "    The user is created, but it has NO access key yet."
  echo "    1. Click into the user 'zdr-coder' (from the users list)"
  echo "    2. Open the 'Security credentials' tab (NOT 'Permissions')"
  echo "    3. Scroll down to 'Access keys' section"
  echo "    4. Click 'Create access key'"
  echo "    5. Use case prompt:"
  echo "         Choose: 'Command Line Interface (CLI)'"
  echo "         Check the confirmation checkbox at bottom"
  echo "         Click Next"
  echo "    6. Description tag (optional): 'zdr-coder-skypilot'"
  echo "    7. Click 'Create access key'"
  echo "    8. ⚠️  ONE-TIME VIEW screen ⚠️"
  echo "         COPY the Access Key ID (starts with AKIA...)"
  echo "         COPY the Secret Access Key (long random string)"
  echo "         Once you close this page, the Secret cannot be shown again."
  echo
  read -rp "Press Enter when you have BOTH Access Key ID AND Secret ready..." _

  echo
  echo "  Now we'll run 'aws configure'. It will prompt for:"
  echo "    AWS Access Key ID:     paste your AKIA... value"
  echo "    AWS Secret Access Key: paste your secret"
  echo "    Default region name:   us-east-2  (Ohio — best Capacity Block availability)"
  echo "                                       or us-east-1 (Virginia — best quota coverage)"
  echo "    Default output format: json (or just press Enter)"
  echo

  aws configure
  green "  ✓ AWS credentials configured (~/.aws/credentials)"

  echo
  echo "═══ STEP 3: GPU quota requests (1-4 day approval — DO THIS NOW) ═══"
  yellow "  AWS GPU instances need quota approval before you can launch them."
  yellow "  Submit these NOW so they're approved by the time you actually need them."
  echo
  echo "  Open the EC2 Service Quotas page, then SEARCH the filter box for each:"
  echo
  echo "    Filter: 'G and VT'    →  L40S (haiku tier)"
  echo "    Filter: 'P5'          →  H100 (sonnet tier; sometimes 'P4 and P5' combined)"
  echo "    Filter: 'P5e'         →  H200 (opus tier; sometimes 'P5e and P5en')"
  echo
  echo "  For each, click → 'Request increase at account level' → 192 vCPUs"
  echo "  (= one full node = 8× GPU; smaller is fine if you only want 1× or 4×)"
  echo
  yellow "  Note: quota names + IDs vary by AWS internal updates. If a specific"
  yellow "  quota doesn't exist in us-east-2, switch to us-east-1 (N. Virginia)"
  yellow "  — it has the widest GPU SKU coverage for on-demand quotas."
  echo
  echo "  Region-specific URLs (open one):"
  echo "    Ohio:     https://us-east-2.console.aws.amazon.com/servicequotas/home/services/ec2/quotas"
  echo "    Virginia: https://us-east-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas"
  echo
  echo "  Alternative — Capacity Blocks (no quota needed, pre-paid 1-14 day windows):"
  echo "    Ohio:     https://us-east-2.console.aws.amazon.com/ec2/home?region=us-east-2#CapacityBlocks:"
  echo "    Virginia: https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#CapacityBlocks:"
  echo
  open_url "https://us-east-2.console.aws.amazon.com/servicequotas/home/services/ec2/quotas"
  read -rp "Press Enter when you've submitted the relevant quota requests (or skipped)..." _

  echo "Current quota status (you'll get email approval; recheck with this command):"
  aws service-quotas list-service-quotas --service-code ec2 \
    --query 'Quotas[?contains(QuotaName, `P5`) || contains(QuotaName, `G and VT`)].[QuotaName,Value]' \
    --output table 2>&1 | head -20 || true

  green "  ✓ AWS quotas requested. Approval emails arrive in 1–4 days."
  yellow "  Until quotas are non-zero, sonnet/opus AWS launches will fail with ResourcesUnavailableError."

  echo
  echo "═══ STEP 4: Bedrock model access for Anthropic Claude (~3 min) ═══"
  yellow "  Skip if you don't want managed Anthropic Claude via AWS Bedrock."
  yellow "  Only relevant if you attached the AmazonBedrockFullAccess policy."
  echo
  echo "  Why: gives you BAA-eligible frontier Claude (Opus 4.7, Sonnet 4, Haiku 4)"
  echo "  via LiteLLM model IDs 'bedrock-opus', 'bedrock-sonnet', 'bedrock-haiku'."
  echo "  Per-token pricing, no GPU quota needed, no self-host cost."
  echo
  yellow "  Note: AWS retired the old 'Model access' page in 2026. Foundation"
  yellow "  models now auto-enable on first invocation. ONLY Anthropic Claude"
  yellow "  still requires a one-time use-case form, triggered during your first"
  yellow "  call to the model in the Playground."
  echo
  echo "  Steps to pre-approve (avoids a surprise prompt on your first real LiteLLM call):"
  echo "  1. Open Bedrock Model catalog in the SAME region you used above:"
  echo "       Ohio:     https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/model-catalog"
  echo "       Virginia: https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/model-catalog"
  echo "  2. Filter for 'Anthropic'"
  echo "  3. Click into each model you want to enable (Opus, Sonnet, Haiku)"
  echo "  4. Click 'Open in Playground' (top right of model page)"
  echo "  5. Type any test message ('hello' works) and click Run"
  echo "  6. AWS will prompt an inline 'Use case' form on FIRST call:"
  echo "       - Use case: 'Internal coding assistant'"
  echo "       - Industry / details: brief plain prose, e.g."
  echo "         'Self-hosted coding agent; Bedrock as BAA-eligible inference fallback.'"
  echo "  7. Accept Anthropic's EULA, submit form"
  echo "  8. Approval is usually immediate to ~1 hour"
  echo "  9. Repeat for each Claude model you plan to use"
  echo
  open_url "https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/model-catalog"
  read -rp "Press Enter when Anthropic use-case form is submitted (or skipped)..." _

  green "  ✓ AWS setup complete."
  echo "  Path 2 (self-hosted on AWS): waits for GPU quota approval (1-4 days)."
  echo "  Path 1 (Bedrock managed Claude): waits for model access approval (~1 hour)."
}

setup_azure() {
  hr
  bold "🟦 Azure — hyperscaler (BAA auto-in-DPA + FedRAMP)"


  if [[ -f "$HOME/.azure/msal_token_cache.json" ]] && ! confirm "Azure already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Azure" || return 0

  ensure_tool az "brew install azure-cli"
  echo "Running az login (opens browser)..."
  az login
  green "  ✓ Azure CLI authenticated"
}

setup_lambda() {
  hr
  bold "🟪 Lambda Labs — SOC2 Type II + ISO 27001/17/701/22301"
  yellow "  ~32K H100 fleet, on-demand single + multi-GPU works without quota wait."
  yellow "  No public H200 SKU though — opus tier won't land here."


  if [[ -f "$HOME/.lambda_cloud/lambda_keys" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Lambda" || return 0

  echo "Sign-up flow:"
  echo "  1. Sign up at https://lambdalabs.com (now lambda.ai)"
  echo "  2. Dashboard → API Keys → Generate API Key"
  echo "  3. Copy the key (one-time view)"
  open_url "https://cloud.lambda.ai/api-keys/cloud-api"
  echo
  read -rp "Press Enter when you have the API key ready..." _

  prompt_secret LAMBDA_KEY "Paste Lambda API key (hidden)"

  mkdir -p "$HOME/.lambda_cloud"
  echo "api_key = $LAMBDA_KEY" > "$HOME/.lambda_cloud/lambda_keys"
  chmod 600 "$HOME/.lambda_cloud/lambda_keys"
  green "  ✓ Wrote ~/.lambda_cloud/lambda_keys"
}

setup_oci() {
  hr
  bold "🟧 OCI (Oracle Cloud) — SOC2 II + ISO 27001/17/18 + FedRAMP High"
  yellow "  65K-GPU H200 supercluster (largest verified). EY-attested HIPAA program."
  yellow "  Sales-free signup; GPU service-limit increase via console form (1-4 days)."


  if [[ -f "$HOME/.oci/config" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "OCI" || return 0

  ensure_tool oci "brew install oci-cli"

  echo "═══ STEP 1: Account signup (5 min, instant) ═══"
  echo "  New account:   https://signup.oraclecloud.com"
  echo "                 \$300 / 30-day free credit auto-applied; CC required for ID verification"
  echo "  Existing user: https://www.oracle.com/cloud/sign-in.html"
  echo "                 (use this if you already have an Oracle Cloud account)"
  echo "  Complete onboarding → land on OCI Console"
  echo
  yellow "  ⚠️  CRITICAL: Pick your HOME REGION carefully — it's PERMANENT."
  yellow "  OCI does not let you change your home region after signup. You can"
  yellow "  subscribe to additional regions later for capacity, but home is frozen."
  echo
  echo "  Recommended home regions:"
  echo "    US (default):        us-ashburn-1   (Virginia — widest GPU coverage,"
  echo "                                          65K H200 supercluster, all SKUs GA)"
  echo "    US West Coast:       us-phoenix-1   or  us-sanjose-1"
  echo "    EU sovereignty:      eu-frankfurt-1 (Germany — flagship EU region)"
  echo "    UK sovereignty:      uk-london-1"
  echo
  yellow "  If you're not sure: pick us-ashburn-1. It has the most H100/H200/L40S"
  yellow "  capacity and the largest service catalog of any OCI region."
  open_url "https://signup.oraclecloud.com"
  echo
  read -rp "Press Enter when your OCI account is ready..." _

  echo "═══ STEP 2: oci-cli config (interactive, ~5 min) ═══"
  echo "  Have these 2 OCIDs ready before running 'oci setup config'."
  echo "  Open these OCI Console pages in browser tabs first:"
  echo
  echo "  • USER OCID (starts with 'ocid1.user.oc1..'):"
  echo "      Path A: Top-right profile icon → 'My profile'"
  echo "              → field labeled 'OCID' → click 'Show' → click 'Copy'"
  echo "      Path B (if 'My profile' isn't there):"
  echo "              Hamburger menu (≡) → Identity & Security → Identity → Domains"
  echo "              → click Default domain → Users → your username"
  echo "              → 'OCID' field → Show → Copy"
  echo "      Direct URL: https://cloud.oracle.com/identity/domains/my-profile"
  open_url "https://cloud.oracle.com/identity/domains/my-profile"
  echo
  echo "  • TENANCY OCID (starts with 'ocid1.tenancy.oc1..'):"
  echo "      Top-right profile icon → 'Tenancy: <your-tenancy-name>'"
  echo "      → 'OCID' field at top of tenancy page → click 'Show' → click 'Copy'"
  echo
  read -rp "Press Enter when both OCIDs are copied (or in your clipboard manager)..." _

  echo
  echo "  Now running 'oci setup config'. Answer the prompts:"
  echo
  echo "    Config location:       just press Enter (uses ~/.oci/config)"
  echo "    User OCID:             paste your user OCID"
  echo "    Tenancy OCID:          paste your tenancy OCID"
  echo "    Region:                type exactly:  us-ashburn-1"
  echo "                           (or whatever HOME REGION you picked at signup)"
  echo "                           ⚠️  The CLI prompts you with 80+ region options."
  echo "                           ⚠️  You can either type the name OR an index from"
  echo "                           ⚠️  the list (us-ashburn-1 was index 72 as of 2026)."
  echo "                           ⚠️  REGION MUST MATCH YOUR HOME REGION from signup."
  echo "    Generate new API key:  Y  (the script will create the RSA pair for you)"
  echo "    Directory for keys:    just press Enter (uses ~/.oci)"
  echo "    Key name:              just press Enter (uses 'oci_api_key')"
  echo "    Passphrase:            type:  N/A   (literally those 3 chars — it's the"
  echo "                           OCI CLI's 'no passphrase' sentinel. Pressing Enter"
  echo "                           alone may error. Disk encryption is the defense."
  echo "                           Confirm with N/A again if it asks twice.)"
  echo
  oci setup config
  green "  ✓ ~/.oci/config + RSA key pair generated"

  echo
  echo "═══ STEP 2b: Upload public key to OCI Console (MANDATORY) ═══"
  yellow "  CRITICAL: OCI doesn't yet know about the RSA key it just generated."
  yellow "  Without this upload, every oci-cli + SkyPilot command fails with"
  yellow "  NotAuthenticated. This is the most-missed step in OCI setup."
  echo
  echo "  Below is your public key — copy the ENTIRE block (including the"
  echo "  -----BEGIN/-----END lines) and paste it into the OCI Console:"
  hr
  cat "$HOME/.oci/oci_api_key_public.pem"
  hr
  echo
  echo "  Steps:"
  echo "  1. Open: https://cloud.oracle.com/identity/domains/my-profile"
  echo "     (or via menu: Identity & Security → Identity → Domains → Default"
  echo "      → Users → click your user)"
  echo "  2. Find the 'API Keys' section on the user details page"
  echo "  3. Click 'Add API Key'"
  echo "  4. Choose 'Paste a public key' → paste the entire block above → 'Add'"
  echo "  5. OCI shows a 'Fingerprint' — verify it matches the one printed by"
  echo "     'oci setup config' (both derive from the same key)."
  echo
  open_url "https://cloud.oracle.com/identity/domains/my-profile"
  read -rp "Press Enter when the public key is uploaded to OCI Console..." _

  echo
  echo "═══ STEP 3: GPU service-limit increase requests (1-4 day approval) ═══"
  yellow "  Submit NOW so they're approved by the time you need them."
  echo "  Console: https://cloud.oracle.com/limits"
  echo "  Service: Compute → Search 'GPU' → request:"
  echo "    • BM.GPU.H100.8 (8× H100) — request 1 or more"
  echo "    • BM.GPU.H200.8 (8× H200) — request 1 or more"
  echo "    • BM.GPU.L40S.4 (4× L40S) — request 1 or more"
  echo "  Each goes via Support Request form (not a phone call)."
  open_url "https://cloud.oracle.com/limits"
  echo
  read -rp "Press Enter when limit requests submitted (or skipped)..." _
  green "  ✓ OCI setup complete. Limit approvals arrive by email."
}

setup_r2() {
  hr
  bold "☁️  Cloudflare R2 — OPTIONAL bucket for pre-staging opus weights"
  yellow "  Skip unless you specifically want opus-serve scale-to-zero with"
  yellow "  fast (~2 min) cold starts instead of ~25 min. For pod configs"
  yellow "  and serve configs with min_replicas: 1, R2 isn't needed."


  if [[ -f "$HOME/.cloudflare/r2.credentials" && -f "$HOME/.cloudflare/accountid" ]] && ! confirm "Already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "Cloudflare R2" || return 0

  echo "Sign-up flow:"
  echo "  1. Sign up / log in: https://dash.cloudflare.com"
  echo "  2. Search bar → 'R2 Object Storage' (faster than the sidebar)"
  echo "  3. Enable R2 if first time (CC required, 10 GB storage + 1M reads/mo free)"
  echo "  4. Account Details panel (right side) → API Tokens → Manage"
  echo "  5. Create API Token in the 'Account API Tokens' section (NOT User)"
  echo "       - This is the production-recommended type — survives if you leave the org"
  echo "  6. Permissions: 'Object Read & Write' (not Admin, not Bucket)"
  echo "  7. Bucket scope: leave blank (allow all)"
  echo "  8. Copy 3 values:"
  echo "       - Account ID (shown on R2 main page → Account Details panel)"
  echo "       - Access Key ID (32-char hex, on create-success screen)"
  echo "       - Secret Access Key (64-char hex — ONE-TIME view, copy immediately)"
  open_url "https://dash.cloudflare.com"
  echo
  read -rp "Press Enter when you have all 3 values ready..." _

  read -rp "Paste Cloudflare Account ID: " R2_ACCOUNT_ID
  read -rp "Paste R2 Access Key ID: " R2_ACCESS_KEY_ID
  prompt_secret R2_SECRET "Paste R2 Secret Access Key (hidden)"

  mkdir -p "$HOME/.cloudflare"
  echo -n "$R2_ACCOUNT_ID" > "$HOME/.cloudflare/accountid"
  chmod 600 "$HOME/.cloudflare/accountid"

  cat > "$HOME/.cloudflare/r2.credentials" <<EOF
[r2]
aws_access_key_id = $R2_ACCESS_KEY_ID
aws_secret_access_key = $R2_SECRET
EOF
  chmod 600 "$HOME/.cloudflare/r2.credentials"

  green "  ✓ Wrote ~/.cloudflare/accountid"
  green "  ✓ Wrote ~/.cloudflare/r2.credentials"
}

setup_gcp() {
  hr
  bold "🟧 GCP — hyperscaler (BAA via console + FedRAMP)"


  if gcloud auth application-default print-access-token >/dev/null 2>&1 && ! confirm "GCP already configured. Reconfigure?"; then
    green "  ✓ Skipped (already configured)"
    return
  fi

  ask_setup "GCP" || return 0

  ensure_tool gcloud "brew install --cask google-cloud-sdk"
  echo "Running gcloud auth (opens browser)..."
  gcloud auth application-default login
  green "  ✓ GCP CLI authenticated"
}

# ─────────────────────────── run ───────────────────────────────

for backend in "${BACKENDS[@]}"; do
  case "$backend" in
    runpod) setup_runpod ;;
    vast)   setup_vast ;;
    lambda) setup_lambda ;;
    aws)    setup_aws ;;
    oci)    setup_oci ;;
    azure)  setup_azure ;;
    gcp)    setup_gcp ;;
    r2)     setup_r2 ;;
    # legacy/deprecated backends — kept for tier-override compatibility
    verda)  setup_verda ;;
    nebius) setup_nebius ;;
  esac
done

# ────────────────────── final sky check ────────────────────────

hr
bold "✅ All backends configured. Running sky check..."
hr

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# sky check accepts compute backends; "r2" is a storage layer (Cloudflare),
# named differently in sky check, so filter it out of the compute check list
# and check it separately if configured.
COMPUTE_BACKENDS=()
for b in "${BACKENDS[@]}"; do
  [[ "$b" != "r2" ]] && COMPUTE_BACKENDS+=("$b")
done
"$SKY" check "${COMPUTE_BACKENDS[@]}" 2>&1 | grep -E "enabled|disabled|✓|Reason" || true

# Check R2 separately if user configured it (storage capability)
if [[ -f "$HOME/.cloudflare/r2.credentials" ]]; then
  echo
  "$SKY" check cloudflare 2>&1 | grep -E "Cloudflare|enabled|disabled|Reason" || true
fi

hr
bold "🎉 Setup complete for ZDR_TIER=$ZDR_TIER"
echo
echo "Next steps:"
echo "  • See what GPUs are available:    source .venv-sky/bin/activate && sky show-gpus L40S:1"
echo "  • Launch the haiku tier:           sky launch -c haiku-pod sky/haiku-pod.yaml"
echo "  • Launch scale-to-zero serverless: sky serve up -n haiku-serve sky/haiku-serve.yaml"
echo "  • Start the LiteLLM proxy:         ./start.command  (mac) | ./start.bat  (win)"
