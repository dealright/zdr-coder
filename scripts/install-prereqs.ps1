# zdr-coder prerequisites for Windows.
# Run in PowerShell as Administrator:
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\scripts\install-prereqs.ps1
#
# Note: the deploy/destroy/smoketest scripts are bash. Run them via WSL2 or Git Bash.
# WSL2 is strongly recommended — Docker Desktop on Windows uses it anyway.

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this script as Administrator."
    exit 1
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Error "Chocolatey not installed. Install it from https://chocolatey.org/install"
    exit 1
}

Write-Host "-> Installing CLI tools via Chocolatey..." -ForegroundColor Cyan
choco install -y `
    docker-desktop `
    wireguard `
    jq `
    curl `
    git `
    vscodium

# Cline extension via VSCodium CLI
Write-Host "-> Installing Cline extension..." -ForegroundColor Cyan
$codium = "$env:LOCALAPPDATA\Programs\VSCodium\bin\codium.cmd"
if (Test-Path $codium) {
    & $codium --install-extension saoudrizwan.claude-dev
} else {
    Write-Warning "VSCodium CLI not on PATH yet. Install Cline manually after VSCodium starts."
}

Write-Host ""
Write-Host "Prerequisites installed." -ForegroundColor Green
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Open Docker Desktop once to complete setup."
Write-Host "  2. Inside WSL2 or Git Bash:"
Write-Host "       cp .env.example .env"
Write-Host "       `$EDITOR .env                  # set RUNPOD_API_KEY"
Write-Host "       ./scripts/deploy.sh sonnet    # or: haiku | opus | all"
