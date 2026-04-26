@echo off
:: ANS IPU Console — cloud launcher
:: Double-click to download and run the latest version from GitHub.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "irm 'https://raw.githubusercontent.com/AppNetOnline/ans-osd-ipu/main/Start-ANSIPUGUI.ps1' | iex"
