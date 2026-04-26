@echo off
:: ─────────────────────────────────────────────────────────────────────────────
::  ANS IPU Console launcher
::  Double-click to run.  Self-elevates to admin if needed.
:: ─────────────────────────────────────────────────────────────────────────────

:: Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting admin privileges...
    powershell -NoProfile -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Run the GUI
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0gui\Invoke-OSDCloudIPUGUI.ps1"
