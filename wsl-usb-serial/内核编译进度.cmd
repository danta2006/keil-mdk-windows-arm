@echo off
chcp 65001 >nul
title kernel build progress
set "SH="
for /f "delims=" %%i in ('wsl.exe -d Ubuntu2204 -e wslpath -u "%~dp0progress.sh"') do set "SH=%%i"
if not defined SH (
    echo Cannot resolve progress.sh
    pause
    exit /b 1
)
wsl.exe -d Ubuntu2204 -e bash "%SH%"
echo.
echo Monitor exited. Build keeps running in background.
pause
