@echo off
setlocal
title Relay Imagegen - Simple Setup
echo.
echo ============================================
echo   Relay Imagegen - Codex Simple Setup
echo ============================================
echo.
echo This wizard installs the skill and saves your relay settings.
echo Your API key will be entered as hidden secure input.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set EXIT_CODE=%ERRORLEVEL%
echo.
if "%EXIT_CODE%"=="0" (
  echo Setup completed. Fully restart Codex before generating images.
) else (
  echo Setup failed with exit code %EXIT_CODE%.
)
echo.
pause
exit /b %EXIT_CODE%
