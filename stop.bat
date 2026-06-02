@echo off
cd /d "%~dp0"
wsl bash -c "./scripts/openhands-down.sh ; ./scripts/destroy.sh api"
echo.
echo Everything stopped. Your API keys in .env are preserved.
pause
