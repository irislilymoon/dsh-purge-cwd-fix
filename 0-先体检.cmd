@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge cwd problem - DIAGNOSE (read-only)
echo  Safe: this does not change any file.
echo ============================================================
echo.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\diagnose.ps1"

echo.
echo ------------------------------------------------------------
echo  Done. If anything is [FAIL], read README.md (Troubleshooting).
echo ------------------------------------------------------------
pause
