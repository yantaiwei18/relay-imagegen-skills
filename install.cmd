@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set EXIT_CODE=%ERRORLEVEL%
echo.
if not "%EXIT_CODE%"=="0" echo Installation failed with exit code %EXIT_CODE%.
if "%EXIT_CODE%"=="0" echo Installation completed. Restart Codex once.
pause
exit /b %EXIT_CODE%

