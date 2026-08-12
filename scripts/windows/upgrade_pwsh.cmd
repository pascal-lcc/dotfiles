@echo off
chcp 65001 >nul

:: 🌟 核心魔法：檢查是不是從既有的環境生出來的
:: 如果是，我們用 start 指令強迫它「靈魂出竅」，開一個完全獨立、不受目前 pwsh 污染的黑色 CMD 新視窗
if "%~1"=="--detached" goto :RUN_UPDATE

start "Scoop PowerShell Updater" /wait cmd /c "%~f0" --detached
exit /b

:RUN_UPDATE
echo --------------------------------------------------
echo [*] 正在跨環境安全升級 Scoop 版 PowerShell 7 (pwsh)...
echo --------------------------------------------------

:: 叫出系統內建 5.1 引擎執行
powershell -NoProfile -ExecutionPolicy Bypass -Command "scoop update pwsh"

echo.
echo [√] 升級程序執行完畢！
pause
exit
