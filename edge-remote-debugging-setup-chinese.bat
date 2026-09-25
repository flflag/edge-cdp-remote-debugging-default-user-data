@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0edge-remote-debugging-setup-chinese.ps1"
pause
