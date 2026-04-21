@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

set "SRC_BASE=%LOCALAPPDATA%"
set "DST_BASE=D:\LocalMoved"
set "LOG=%~dp0move_local_to_d_safe.log"

echo ======================================================== > "%LOG%"
echo START: %date% %time% >> "%LOG%"
echo SRC_BASE=%SRC_BASE% >> "%LOG%"
echo DST_BASE=%DST_BASE% >> "%LOG%"
echo ======================================================== >> "%LOG%"

echo.
echo ==========================================
echo Безопасный перенос AppData\Local на D:
echo ==========================================
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo [ОШИБКА] Запусти bat от имени администратора.
    pause
    exit /b 1
)

if not exist "D:\" (
    echo [ОШИБКА] Диск D: не найден.
    pause
    exit /b 1
)

if not exist "%DST_BASE%" mkdir "%DST_BASE%"

call :move_one "npm-cache"
call :move_one "pip"
call :move_one "pypoetry"
call :move_one "NuGet"
call :move_one "Temp"
call :move_one "Postman"
call :move_one "Postman-Agent"
call :move_one "Figma"
call :move_one "FigmaAgent"
call :move_one "CrashDumps"
call :move_one "D3DSCache"
call :move_one "SquirrelTemp"
call :move_one "cache"

echo.
echo Готово. Лог: %LOG%
pause
exit /b 0

:move_one
set "NAME=%~1"
set "SRC=%SRC_BASE%\%NAME%"
set "DST=%DST_BASE%\%NAME%"

echo.
echo ------------------------------------------
echo Обработка: %NAME%
echo ------------------------------------------

if not exist "%SRC%" (
    echo [SKIP] Не найдена папка: %SRC%
    exit /b 0
)

dir /AL "%SRC%" >nul 2>&1
if not errorlevel 1 (
    echo [SKIP] Уже ссылка: %SRC%
    exit /b 0
)

if not exist "%DST%" mkdir "%DST%"

robocopy "%SRC%" "%DST%" /E /MOVE /R:1 /W:1 >> "%LOG%" 2>&1

if exist "%SRC%" (
    dir /b "%SRC%" >nul 2>&1
    if not errorlevel 1 (
        echo [ERR ] Папка не пуста, пропуск: %SRC%
        exit /b 1
    )
)

if exist "%SRC%" rd "%SRC%" 2>>"%LOG%"
mklink /J "%SRC%" "%DST%" >> "%LOG%" 2>&1

if errorlevel 1 (
    echo [ERR ] Не удалось создать junction: %NAME%
    exit /b 1
)

echo [OK] %NAME%
exit /b 0