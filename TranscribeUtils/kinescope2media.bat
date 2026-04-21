:: ==============================
:: kinescope2media.bat
:: Скачивает MP3 или MP4 с ссылки Kinescope (или YouTube, Vimeo и т.д.)
:: Если yt-dlp.exe нет в папке — скачивает его автоматически.
:: Требует: ffmpeg (путь указан ниже в --ffmpeg-location)
:: ==============================

:: --- Отключаем вывод команд в консоль ---
@echo off

:: --- Устанавливаем кодировку UTF-8 для корректного отображения текста ---
chcp 65001 >nul

:: --- Создаём локальную область переменных ---
setlocal

:: --- Директория, где лежит этот .bat ---
set "SCRIPT_DIR=%~dp0"

:: --- Путь к yt-dlp.exe (в той же папке, что и батник) ---
set "YTDLP=%SCRIPT_DIR%yt-dlp.exe"

:: --- Проверяем, существует ли yt-dlp.exe ---
if not exist "%YTDLP%" (
    echo ⚠ yt-dlp.exe не найден. Пытаюсь скачать последнюю версию с GitHub...

    :: Проверяем, доступен ли PowerShell
    where powershell >nul 2>&1
    if errorlevel 1 (
        echo ❌ PowerShell не найден. Скачивание yt-dlp невозможно.
        echo Скачай yt-dlp.exe вручную и положи рядом с этим .bat файлом.
        pause
        exit /b
    )

    :: Скачиваем yt-dlp.exe в ту же папку, где лежит батник
    powershell -Command "try { Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile '%YTDLP%' -UseBasicParsing } catch { exit 1 }"

    :: Проверяем, скачался ли файл
    if not exist "%YTDLP%" (
        echo ❌ Не удалось скачать yt-dlp.exe.
        echo Открой ссылку вручную: https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe
        echo И сохрани файл как: %YTDLP%
        pause
        exit /b
    )

    echo ✅ yt-dlp.exe успешно скачан: "%YTDLP%"
    echo.
)

:: --- Проверяем, передана ли ссылка как аргумент ---
if "%~1"=="" (
    echo Использование: kinescope2media.bat [ссылка]
    echo Пример: kinescope2media.bat https://kinescope.io/ID
    pause
    exit /b
)
:: Если пользователь не передал ссылку — выводим пример и завершаем выполнение.


:: --- Запрашиваем у пользователя формат для скачивания ---
:choose_format
set /p FORMAT=Введите формат (mp3/mp4):
:: /p означает — «ввести значение и сохранить в переменной FORMAT»
if /i "%FORMAT%"=="mp3" goto get_name
if /i "%FORMAT%"=="mp4" goto get_name
:: /i делает проверку без учёта регистра (MP3 = mp3)
echo Неверный ввод. Попробуйте снова.
goto choose_format
:: Если пользователь ввёл что-то другое — повторить ввод.

:get_name
:: --- Спрашиваем имя файла (без расширения) ---
set /p FILENAME=Введите имя файла (без расширения):

::: --- Создаём папки, если их нет ---
if not exist "data\mp3" mkdir "data\mp3"
if not exist "data\mp4" mkdir "data\mp4"

:: --- Путь к ffmpeg (как у тебя было) ---
set "FFMPEG_PATH="D:\DEV\lib\ffmpeg-8.0-essentials_build\bin"

:: --- Выбираем действие в зависимости от формата ---
if /i "%FORMAT%"=="mp3" (
    :: Скачиваем и конвертируем в MP3
    "%YTDLP%" -x --audio-format mp3 ^
        --ffmpeg-location "%FFMPEG_PATH%" ^
        -o "data/mp3/%FILENAME%.mp3" "%~1"
    echo =========================================
    echo ✅ Готово! Аудио сохранено: data\mp3\%FILENAME%.mp3
    echo =========================================
    pause
    exit /b
)

if /i "%FORMAT%"=="mp4" (
    :: Скачиваем видео в формате MP4
    "%YTDLP%" --merge-output-format mp4 ^
        --ffmpeg-location "%FFMPEG_PATH%" ^
        -o "data/mp4/%FILENAME%.mp4" "%~1"
    echo =========================================
    echo ✅ Готово! Видео сохранено: data\mp4\%FILENAME%.mp4
    echo =========================================
    pause
    exit /b
)

@REM ⚙️ Что делает скрипт
@REM 1) Проверяет, лежит ли yt-dlp.exe рядом с .bat файлом.
@REM    Если нет — автоматически скачивает его с GitHub в ту же папку.
@REM 2) Проверяет, указал ли пользователь ссылку (например, с kinescope.io или YouTube).
@REM 3) Спрашивает у пользователя, в каком формате сохранить — mp3 или mp4.
@REM 4) Спрашивает имя итогового файла.
@REM 5) Создаёт папки data/mp3 и data/mp4, если их нет.
@REM 6) В зависимости от выбора:
@REM    - Если mp3: скачивает и извлекает только аудио;
@REM    - Если mp4: скачивает видео и сохраняет как .mp4.
@REM 7) После завершения — выводит сообщение и ждёт нажатия клавиши.