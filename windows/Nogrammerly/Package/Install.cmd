@echo off
rem Double-click to install Nogrammerly for the current user (no administrator rights needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
pause
