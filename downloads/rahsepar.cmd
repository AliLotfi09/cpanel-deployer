@echo off
setlocal
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rahsepar.ps1" %*
  exit /b %errorlevel%
)

where powershell.exe >nul 2>nul
if %errorlevel%==0 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rahsepar.ps1" %*
  exit /b %errorlevel%
)

echo [ERROR] PowerShell was not found on this system.
exit /b 10
