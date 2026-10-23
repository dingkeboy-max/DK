@echo off
REM NetToggle launcher - double-click to run (auto UAC elevate inside the ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetToggle.ps1"
