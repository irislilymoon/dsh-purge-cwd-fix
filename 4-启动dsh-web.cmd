@echo off
setlocal
chcp 65001 >nul

echo ============================================================
echo  Start dsh web
echo  Keep this window open. Press Ctrl+C to stop the server.
echo ------------------------------------------------------------
echo  dsh web uses the CURRENT directory as the default workspace.
echo  Current directory: %CD%
echo  Tip: open a terminal in your project folder and run this
echo       file, or copy this file into your project folder.
echo ============================================================
echo.

where dsh.cmd >nul 2>nul
if errorlevel 1 (
  echo [ERROR] dsh.cmd was not found in PATH.
  echo         Install @deepseek-ai/dsh first, then open a new terminal.
  echo.
  pause
  exit /b 1
)

call dsh web
echo.
echo dsh web has exited.
pause
