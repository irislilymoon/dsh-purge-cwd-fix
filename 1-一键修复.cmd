@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo  dsh-purge cwd problem - REAPPLY FIX
echo  IMPORTANT: close the running "dsh web" first (Ctrl+C).
echo  This will only modify the dsh-purge plugin files.
echo ============================================================
echo.

where node.exe >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Node.js was not found in PATH.
  echo         Install Node.js or run the .ps1/.mjs manually.
  echo.
  pause
  exit /b 1
)

node "%~dp0scripts\reapply-fix.mjs"
if errorlevel 1 (
  echo.
  echo [FAIL] The plugin layout changed. Read README.md (Update / reinstall),
  echo        or patch by hand using scripts\patch-data\cwd-variable-helper.txt.
  echo.
  pause
  exit /b 1
)

echo.
echo ============================================================
echo  [DONE] Now restart dsh web.
echo  You can double-click the 4th cmd file (start dsh web).
echo ============================================================
pause
