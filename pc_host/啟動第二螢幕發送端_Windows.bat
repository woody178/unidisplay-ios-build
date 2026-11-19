@echo off
chcp 65001 >nul
title UniDisplay 跨平台第二螢幕 - PC 發送端
cd /d "%~dp0"

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [錯誤] 找不到 Python！請先於 Windows 安裝 Python 3.10+ (勾選 Add Python to PATH)。
    pause
    exit /b 1
)

echo 正在啟動 UniDisplay 跨平台第二螢幕發送端...
python unidisplay_host.py
pause
