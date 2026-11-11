@echo off
rem Remote for ADI-2 - Windows-Diagnose. Liest nur aus, aendert nichts.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
echo.
pause
