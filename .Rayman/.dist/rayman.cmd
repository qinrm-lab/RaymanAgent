@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rayman.ps1" %*
exit /b %ERRORLEVEL%
