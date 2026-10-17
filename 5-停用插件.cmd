@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge - DISABLE (reversible)
echo  * Reverts the plugin patches applied to DSH program files
echo  * Removes dsh-purge from the profile bundle list
echo  * Keeps plugin files / deps / rules / prompt for re-enable
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\disable-plugin.ps1" %*
echo.
echo To enable again: double-click the 6th cmd file (ENABLE AGAIN).
pause
