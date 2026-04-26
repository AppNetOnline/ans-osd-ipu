@echo off
:: ANS IPU Console — test mode (no admin or OSD module required)
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0gui\Invoke-OSDCloudIPUGUI.ps1" -TestMode
