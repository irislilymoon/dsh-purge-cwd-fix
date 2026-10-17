@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge - ENABLE AGAIN (restore disabled plugin)
echo  * Adds dsh-purge back to the profile bundle list
echo  * Re-applies the plugin patches to DSH program files
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\enable-plugin.ps1" %*
echo.
echo Restart dsh web after this.
pause
