@echo off
setlocal

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\all.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Logs:
echo   .\log\all-summary.log
echo   .\log\all-01-repair.log
echo   .\log\all-02-install.log
echo   .\log\all-03-postcheck.log
echo   .\log\1.log
echo   .\log\2.log
echo   .\log\3.log
echo   .\log\4.log

exit /b %EXIT_CODE%
