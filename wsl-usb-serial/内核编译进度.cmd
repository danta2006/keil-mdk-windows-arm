@echo off
chcp 65001 >nul
title kernel build progress
wsl.exe -d Ubuntu2204 -e bash /mnt/c/Users/surface/Documents/windows-on-arm-embedded/progress.sh
echo.
echo Monitor exited. Build keeps running.
pause
