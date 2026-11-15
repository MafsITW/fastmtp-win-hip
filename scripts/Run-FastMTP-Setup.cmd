@echo off
rem Close LM Studio's loaded model and other GPU-heavy apps (ComfyUI, games) first so VRAM numbers are clean.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FastMTP-Setup.ps1" %*
echo.
pause
