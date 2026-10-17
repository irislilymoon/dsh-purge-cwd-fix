@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge cwd fix - UNDO THE FIX
echo ------------------------------------------------------------
echo  WHAT IT DOES:
echo    Restores index.js / desktop.js from the automatic backups
echo    created by 1-reapply-fix before it wrote the patch.
echo    The dsh-purge plugin stays installed.
echo.
echo  IMPORTANT:
echo    After this, the current DSH shows the "{{cwd}}" error again
echo    (expected). It is NOT uninstalling the plugin.
echo    - Re-apply the fix : 1-reapply-fix.cmd
echo    - Stop using it    : 5-disable / 7-uninstall
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\rollback.ps1" %*
echo.
pause
