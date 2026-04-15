@echo off
setlocal

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\collect-worker-diag.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Logs:
echo   .\log\1.log
echo   .\log\2.log
echo   .\log\3.log
echo   .\log\4.log

exit /b %EXIT_CODE%
