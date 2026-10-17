@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (set "PSEXE=powershell") else (set "PSEXE=pwsh")

echo ============================================================
echo  dsh-purge cwd problem - VERIFY dsh web
echo  WARNING: this starts a temporary dsh web and calls the model
echo           once (a small token cost). Close other dsh web first.
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\verify-dsh-web.ps1"
if errorlevel 1 (
  echo.
  echo [FAIL] Read README.md (Troubleshooting) for details.
  echo.
  pause
  exit /b 1
)

echo.
echo [PASS] dsh web conversation works.
pause
