@echo off
chcp 65001 >nul
setlocal

set "PS1=%~dp0video_downloader.ps1"

if not exist "%PS1%" (
    echo Script not found: %PS1%
    pause
    exit /b 1
)

where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
)

echo.
pause
