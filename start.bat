@echo off
REM Double-click launcher for Windows. Brings up the LiteLLM proxy +
REM OpenHands web UI and opens it in your default browser.
REM
REM Prereqs (one-time):
REM   - Docker Desktop installed and running
REM   - WSL2 enabled (Docker Desktop installs this)
REM   - .env file in this folder with GROQ_API_KEY set

cd /d "%~dp0"

REM Check Docker is up
docker info >nul 2>&1
if errorlevel 1 (
    echo Docker Desktop is not running. Starting it...
    start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    echo Waiting for Docker to be ready...
    :wait_docker
    timeout /t 3 /nobreak >nul
    docker info >nul 2>&1
    if errorlevel 1 goto wait_docker
)

REM Check .env has the key
findstr /B "GROQ_API_KEY=" .env >nul 2>&1
if errorlevel 1 (
    echo Missing Groq API key. Opening .env file — paste your key from
    echo console.groq.com on the GROQ_API_KEY= line and save.
    notepad .env
    pause
    exit /b 1
)

REM Run the bash scripts via WSL (Docker Desktop installs WSL2)
wsl bash -c "./scripts/api-up.sh && ./scripts/openhands-up.sh"

REM Open the web UI
start http://localhost:3000

echo.
echo Stack is running. Close this window to leave it running in background.
echo To stop: double-click stop.bat in this folder.
pause
