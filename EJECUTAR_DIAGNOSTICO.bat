@echo off
rem GPU BOOSTER 920MX - Fase 1: diagnostico (solo lectura, no modifica nada)
rem Se pide administrador solo para poder medir FPS con PresentMon (lectura de eventos ETW).
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador para poder medir FPS...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Diagnostico.ps1" %*
echo.
pause
