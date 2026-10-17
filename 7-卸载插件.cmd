@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge - FULL UNINSTALL (irreversible)
echo  * Reverts all plugin patches from DSH program files
echo  * Removes the plugin from the profile and deletes its files
echo  * Deletes plugin data (rules / drill DB), after a snapshot
echo  * Other plugins are NOT touched
echo ============================================================
echo.
echo Close dsh web before continuing (the script checks it).
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-plugin.ps1" %*
echo.
pause
