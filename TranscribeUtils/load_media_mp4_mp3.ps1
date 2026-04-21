# Объявление параметров скрипта.
# Скрипт может принимать URL сразу при запуске:
# .\script.ps1 -Url "https://..."
param(
    [string]$Url
)

# ======================================================================
# DIRECT MEDIA LOADER
# ======================================================================
#
# Что делает данный PowerShell-скрипт:
#
# Скрипт скачивает медиа по ссылке в одном из двух режимов:
# - MP3
# - MP4
#
# Он использует yt-dlp + ffmpeg и поддерживает:
# - ввод URL вручную или через параметр -Url
# - выбор формата mp3/mp4
# - анализ доступных форматов видео
# - выбор качества через меню
# - ручной ввод video/audio format id
# - fallback-попытки скачивания, если основной способ не сработал
# - поддержку cookies.txt для YouTube
# - sanitization имени файла
#
# Основной сценарий:
#
# 1. Проверяет наличие:
#    - yt-dlp.exe рядом со скриптом
#    - ffmpeg.exe
#    - ffprobe.exe
#
# 2. Создаёт папки:
#    - data\mp3
#    - data\mp4
#
# 3. Получает URL:
#    - из параметра -Url
#    - или спрашивает у пользователя
#
# 4. Спрашивает формат:
#    - mp3
#    - mp4
#
# 5. Для mp3:
#    - спрашивает имя файла
#    - скачивает аудио
#    - конвертирует в mp3
#    - при ошибке пробует fallback-селекторы
#
# 6. Для mp4:
#    - получает список форматов через yt-dlp -F
#    - парсит видео и аудио форматы
#    - автоматически подбирает лучшие варианты 1080/720/480/360
#    - показывает меню качества
#    - скачивает выбранный вариант
#    - при ошибке пробует fallback-селекторы
#
# 7. Показывает итог:
#    - путь к готовому файлу
#    - какая стратегия скачивания сработала
#
# Особенности:
#
# - Для YouTube может использовать Node.js runtime
# - Если рядом есть cookies.txt, он будет использован
# - Имя файла очищается от недопустимых символов Windows
# - Ошибки внешних exe-команд обрабатываются вручную через $LASTEXITCODE
# ======================================================================

# Если в PowerShell-командах возникает ошибка — останавливаем выполнение.
$ErrorActionPreference = "Stop"

# Для внешних .exe-команд не включаем поведение "ошибка как исключение",
# чтобы можно было вручную анализировать $LASTEXITCODE.
$PSNativeCommandUseErrorActionPreference = $false

# Настройка UTF-8 для корректной работы с русским текстом и Unicode-символами.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Дополнительно переключаем кодовую страницу консоли в UTF-8.
chcp 65001 | Out-Null

# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

# Папка, в которой лежит сам .ps1-скрипт.
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

# Полный путь к yt-dlp.exe рядом со скриптом.
$YtDlp      = Join-Path $ScriptDir "yt-dlp.exe"

# Путь к cookies.txt рядом со скриптом.
# Может использоваться для YouTube, если нужен доступ через cookies.
$CookiesTxt = Join-Path $ScriptDir "cookies.txt"

# Каталог, где находятся ffmpeg.exe и ffprobe.exe.
$FfmpegDir  = "D:\DEV\lib\ffmpeg-8.0-essentials_build\bin"

# Каталог для сохранения mp3-файлов.
$Mp3Dir     = Join-Path $ScriptDir "data\mp3"

# Каталог для сохранения mp4-файлов.
$Mp4Dir     = Join-Path $ScriptDir "data\mp4"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Normalize-Input {
    param([string]$Value)

    # Если значение равно $null — сразу возвращаем $null.
    if ($null -eq $Value) { return $null }

    # Убираем пробелы по краям и внешние двойные кавычки.
    # Это полезно, если пользователь вставил URL или имя в кавычках.
    return $Value.Trim().Trim('"')
}

function Ensure-Directory {
    param([string]$Path)

    # Если папки не существует — создаём её.
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Require-File {
    param(
        [string]$Path,
        [string]$Message
    )

    # Проверка обязательного файла/пути.
    # Если файла нет — выводим ошибку и завершаем скрипт с кодом 1.
    if (-not (Test-Path $Path)) {
        Write-Host "ERROR: $Message" -ForegroundColor Red
        Write-Host "  $Path"
        exit 1
    }
}

function Sanitize-FileName {
    param([string]$Name)

    # Если имя пустое или состоит только из пробелов —
    # используем безопасное имя по умолчанию.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "media"
    }

    # Получаем список недопустимых символов для имени файла в Windows.
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name

    # Каждый запрещённый символ заменяем на "_".
    foreach ($ch in $invalidChars) {
        $result = $result.Replace($ch, "_")
    }

    # Сжимаем повторяющиеся пробелы в один.
    $result = $result -replace '\s+', ' '

    # Убираем пробелы по краям.
    $result = $result.Trim()

    # Ограничиваем длину имени файла 120 символами.
    if ($result.Length -gt 120) {
        $result = $result.Substring(0, 120).Trim()
    }

    # Если после очистки имя опять стало пустым — возвращаем "media".
    if ([string]::IsNullOrWhiteSpace($result)) {
        return "media"
    }

    return $result
}

function Get-ExtraArgs {
    param([string]$DownloadUrl)

    # Базовые аргументы для yt-dlp:
    # --no-update             не проверять обновления
    # --retries 20            число повторных попыток
    # --fragment-retries 20   повторные попытки для фрагментов
    # --socket-timeout 30     таймаут сети
    # --concurrent-fragments 4 скачивание нескольких фрагментов параллельно
    # --throttled-rate 100K   порог, ниже которого yt-dlp считает соединение "задушенным"
    $args = @(
        "--no-update",
        "--retries", "20",
        "--fragment-retries", "20",
        "--socket-timeout", "30",
        "--concurrent-fragments", "4",
        "--throttled-rate", "100K"
    )

    # Для YouTube добавляем движок JS runtime = node.
    # Это иногда нужно для корректной обработки сайта.
    if ($DownloadUrl -match "youtube\.com|youtu\.be") {
        $args += @("--js-runtimes", "node")

        # Если рядом со скриптом есть cookies.txt —
        # подключаем cookies для доступа к видео.
        if (Test-Path $CookiesTxt) {
            $args += @("--cookies", $CookiesTxt)
        }
    }

    return $args
}

function Run-YtDlpCapture {
    param([string[]]$Arguments)

    # Сохраняем текущее значение настройки.
    $oldPref = $PSNativeCommandUseErrorActionPreference

    # Временно отключаем поведение "ошибка внешней команды как исключение",
    # чтобы получить stdout/stderr и код завершения вручную.
    $PSNativeCommandUseErrorActionPreference = $false

    try {
        # Запускаем yt-dlp с указанными аргументами.
        # 2>&1 объединяет stderr со stdout, чтобы весь вывод был в одном массиве.
        $output = & $YtDlp @Arguments 2>&1

        # Код завершения внешней команды.
        $code = $LASTEXITCODE

        # Возвращаем хеш-таблицу с выводом и exit-кодом.
        return @{
            Output   = $output
            ExitCode = $code
        }
    }
    finally {
        # Восстанавливаем исходную настройку независимо от результата.
        $PSNativeCommandUseErrorActionPreference = $oldPref
    }
}

function Show-Header {
    # Просто красивый заголовок в консоли.
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "DIRECT MEDIA LOADER" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Ask-Format {
    # Бесконечный цикл до корректного ввода.
    while ($true) {
        $fmt = Normalize-Input (Read-Host "Enter format (mp3/mp4)")

        # Принимаем только mp3 или mp4.
        if ($fmt -in @("mp3", "mp4")) {
            return $fmt.ToLower()
        }

        Write-Host "Enter only mp3 or mp4." -ForegroundColor Yellow
    }
}

function Ask-FileName {
    # Спрашиваем имя файла у пользователя.
    $name = Normalize-Input (Read-Host "Enter output file name without extension")

    # Если не введено ничего — используем имя по умолчанию.
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "media"
    }

    # Возвращаем очищенное безопасное имя файла.
    return (Sanitize-FileName $name)
}

function Parse-Formats {
    param([string[]]$Lines)

    # Сюда будем собирать видеоформаты.
    $videoFormats = @()

    # Сюда будем собирать аудиоформаты.
    $audioFormats = @()

    # Проходим по каждой строке вывода yt-dlp -F.
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        # Пустые строки пропускаем.
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # Нас интересуют только строки, начинающиеся с id формата.
        if ($trimmed -notmatch '^[0-9A-Za-z_-]+\s') { continue }

        # id формата — первый токен до пробела.
        $id = ($trimmed -split '\s+')[0]

        # Если это audio only — сохраняем в список аудиоформатов.
        if ($trimmed -match 'audio only') {
            $audioFormats += [PSCustomObject]@{
                Id          = $id
                Line        = $trimmed
                IsM4a       = ($trimmed -match 'm4a')
                IsAudioOnly = $true
            }
        }
        # Иначе, если строка похожа на видеоформат с разрешением.
        elseif ($trimmed -match '([0-9]{3,4})p|([0-9]{3,4})x([0-9]{3,4})') {
            $height = $null

            # Если указано 720p / 1080p и т.п. — берём высоту.
            if ($trimmed -match '([0-9]{3,4})p') {
                $height = [int]$Matches[1]
            }
            # Если указано как ширина x высота — берём второе число.
            elseif ($trimmed -match '([0-9]{3,4})x([0-9]{3,4})') {
                $height = [int]$Matches[2]
            }

            # Сохраняем информацию о видеоформате.
            $videoFormats += [PSCustomObject]@{
                Id          = $id
                Line        = $trimmed
                Height      = $height
                IsMp4       = ($trimmed -match '\bmp4\b')
                IsVideoOnly = ($trimmed -match 'video only')
            }
        }
    }

    # Возвращаем обе коллекции в одном объекте.
    return @{
        Video = $videoFormats
        Audio = $audioFormats
    }
}

function Get-BestAudioId {
    param($AudioFormats)

    # Сначала предпочитаем m4a-аудио.
    # Среди m4a выбираем то, у которого наибольший битрейт (если он распознан).
    $m4a = $AudioFormats |
        Where-Object { $_.IsM4a } |
        Sort-Object {
            if ($_.Line -match '\s([0-9]+)k(\s|$)') { [int]$Matches[1] } else { 0 }
        } -Descending |
        Select-Object -First 1

    if ($m4a) { return $m4a.Id }

    # Если m4a нет — выбираем просто лучший аудиоформат по битрейту.
    $first = $AudioFormats |
        Sort-Object {
            if ($_.Line -match '\s([0-9]+)k(\s|$)') { [int]$Matches[1] } else { 0 }
        } -Descending |
        Select-Object -First 1

    if ($first) { return $first.Id }

    # Если ничего не нашли — возвращаем $null.
    return $null
}

function Get-BestVideoIdByHeight {
    param(
        $VideoFormats,
        [int]$TargetHeight
    )

    # Предпочитаем формат:
    # - высота <= целевой
    # - mp4
    # - video only
    # Затем выбираем максимальную возможную высоту.
    $preferred = $VideoFormats |
        Where-Object {
            $_.Height -le $TargetHeight -and $_.IsMp4 -and $_.IsVideoOnly
        } |
        Sort-Object Height -Descending |
        Select-Object -First 1

    if ($preferred) { return $preferred.Id }

    # Если такого нет — берём любой формат не выше TargetHeight.
    $fallback = $VideoFormats |
        Where-Object { $_.Height -le $TargetHeight } |
        Sort-Object Height -Descending |
        Select-Object -First 1

    if ($fallback) { return $fallback.Id }

    return $null
}

function Show-FormatsSummary {
    param($Parsed)

    # Выводим краткое резюме по найденным форматам:
    # до 20 видео и до 10 аудио.
    Write-Host ""
    Write-Host "===== VIDEO =====" -ForegroundColor Cyan
    $Parsed.Video |
        Sort-Object Height -Descending |
        Select-Object -First 20 |
        ForEach-Object { Write-Host $_.Line }

    Write-Host ""
    Write-Host "===== AUDIO =====" -ForegroundColor Cyan
    $Parsed.Audio |
        Select-Object -First 10 |
        ForEach-Object { Write-Host $_.Line }

    Write-Host ""
}

function Build-QualityOptions {
    param(
        [string]$AudioId,
        [string]$Id1080,
        [string]$Id720,
        [string]$Id480,
        [string]$Id360
    )

    # Формируем список вариантов, которые будут показаны пользователю в меню.
    $options = @()

    # Универсальный вариант "лучшее доступное".
    $options += [PSCustomObject]@{
        MenuKey  = "1"
        Label    = "Best available"
        Selector = "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b"
    }

    $next = 2

    # Если найден 1080p-видео — добавляем пункт меню.
    if ($Id1080) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "1080p [video $Id1080 + audio $AudioId]"
            Selector = "$Id1080+$AudioId"
        }
        $next++
    }

    # Если найден 720p-видео — добавляем пункт меню.
    if ($Id720) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "720p [video $Id720 + audio $AudioId]"
            Selector = "$Id720+$AudioId"
        }
        $next++
    }

    # Если найден 480p-видео — добавляем пункт меню.
    if ($Id480) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "480p [video $Id480 + audio $AudioId]"
            Selector = "$Id480+$AudioId"
        }
        $next++
    }

    # Если найден 360p-видео — добавляем пункт меню.
    if ($Id360) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "360p [video $Id360 + audio $AudioId]"
            Selector = "$Id360+$AudioId"
        }
        $next++
    }

    # Отдельный режим ручного ввода video id + audio id.
    $options += [PSCustomObject]@{
        MenuKey  = "M"
        Label    = "Manual video id + audio id"
        Selector = $null
    }

    return $options
}

function Ask-QualityModeDynamic {
    param($Options)

    # Красивый вывод меню вариантов качества.
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "AVAILABLE DOWNLOAD OPTIONS" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    foreach ($opt in $Options) {
        Write-Host ("{0}. {1}" -f $opt.MenuKey, $opt.Label)
    }

    Write-Host ""

    while ($true) {
        # Читаем выбор пользователя.
        $mode = Normalize-Input (Read-Host "Choose option")
        $modeUpper = $mode.ToUpper()

        # Ищем выбранный пункт меню.
        $selected = $Options | Where-Object { $_.MenuKey.ToUpper() -eq $modeUpper } | Select-Object -First 1

        if ($selected) {

            # Если выбран ручной режим.
            if ($selected.MenuKey.ToUpper() -eq "M") {
                $vid = Normalize-Input (Read-Host "Enter video id")
                $aud = Normalize-Input (Read-Host "Enter audio id (can be empty)")

                # video id обязателен.
                if ([string]::IsNullOrWhiteSpace($vid)) {
                    Write-Host "Video id is empty." -ForegroundColor Yellow
                    continue
                }

                # Если audio id пустой — возвращаем только video id.
                if ([string]::IsNullOrWhiteSpace($aud)) {
                    return @{
                        Selector = $vid
                        Label    = "MANUAL $vid"
                    }
                }

                # Иначе возвращаем комбинацию video+audio.
                return @{
                    Selector = "$vid+$aud"
                    Label    = "MANUAL $vid+$aud"
                }
            }

            # Для обычного пункта меню возвращаем его selector и label.
            return @{
                Selector = $selected.Selector
                Label    = $selected.Label
            }
        }

        Write-Host "Invalid choice." -ForegroundColor Yellow
    }
}

function Invoke-DirectAttempt {
    param(
        [string[]]$PrefixArgs,
        [string[]]$AttemptArgs,
        [string]$Url
    )

    # Непосредственный запуск yt-dlp:
    # сначала служебные аргументы префикса,
    # затем аргументы конкретной попытки,
    # затем URL.
    & $YtDlp @PrefixArgs @AttemptArgs $Url

    # Код завершения внешней команды.
    $code = $LASTEXITCODE

    return @{
        ExitCode = $code
    }
}

function Invoke-DownloadWithRetry {
    param(
        [string[]]$CommonArgs,
        [string]$PrimarySelector,
        [string]$OutputPath,
        [string]$Mode,
        [string]$Url
    )

    # Эти аргументы нужны для красивого покадрового вывода прогресса.
    $prefixArgs = @(
        "--newline",
        "--progress-template",
        "download:%(progress._percent_str)s | %(progress._speed_str)s | ETA %(progress._eta_str)s | %(info.title)s"
    )

    # Набор стратегий скачивания зависит от режима mp4/mp3.
    if ($Mode -eq "mp4") {
        # Для mp4 предусмотрено несколько попыток с fallback-селекторами.
        $attempts = @(
            [PSCustomObject]@{
                Label = "Primary selector"
                Args  = @("-f", $PrimarySelector) + $CommonArgs
            },
            [PSCustomObject]@{
                Label = "Fallback: best mp4 + m4a"
                Args  = @("-f", "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b") + $CommonArgs
            },
            [PSCustomObject]@{
                Label = "Fallback: <=1080 mp4"
                Args  = @("-f", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b") + $CommonArgs
            },
            [PSCustomObject]@{
                Label = "Fallback: progressive mp4"
                Args  = @("-f", "b[ext=mp4]/b") + $CommonArgs
            },
            [PSCustomObject]@{
                Label = "Fallback: format 18"
                Args  = @("-f", "18/b") + $CommonArgs
            }
        )
    }
    else {
        # Для mp3 меньше вариантов fallback:
        # сначала основной аудиоселектор, затем bestaudio.
        $attempts = @(
            [PSCustomObject]@{
                Label = "Primary selector"
                Args  = @("-f", $PrimarySelector) + $CommonArgs
            },
            [PSCustomObject]@{
                Label = "Fallback: bestaudio"
                Args  = @("-f", "ba/b") + $CommonArgs
            }
        )
    }

    # Последовательно пробуем все стратегии.
    for ($i = 0; $i -lt $attempts.Count; $i++) {
        $attemptNo = $i + 1

        Write-Host ""
        Write-Host ("Attempt {0}/{1}: {2}" -f $attemptNo, $attempts.Count, $attempts[$i].Label) -ForegroundColor Cyan
        Write-Host ""

        # Запуск одной попытки.
        $null = Invoke-DirectAttempt -PrefixArgs $prefixArgs -AttemptArgs $attempts[$i].Args -Url $Url

        # Успех считается только если:
        # 1) yt-dlp завершился с кодом 0
        # 2) итоговый файл реально появился на диске
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutputPath)) {
            return @{
                Success = $true
                Label   = $attempts[$i].Label
            }
        }

        Write-Host ""
        Write-Host "Attempt failed." -ForegroundColor Yellow

        # Если это не последняя попытка — делаем короткую паузу и пробуем fallback.
        if ($attemptNo -lt $attempts.Count) {
            Write-Host "Retrying with fallback..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }

    # Если все попытки исчерпаны — возвращаем признак неуспеха.
    return @{
        Success = $false
        Label   = "All attempts exhausted"
    }
}

# ------------------------------------------------------------
# Prepare
# ------------------------------------------------------------

# Показываем заголовок.
Show-Header

# Проверяем наличие обязательных файлов:
# yt-dlp.exe, ffmpeg.exe, ffprobe.exe.
Require-File -Path $YtDlp -Message "yt-dlp.exe not found next to script:"
Require-File -Path (Join-Path $FfmpegDir "ffmpeg.exe") -Message "ffmpeg.exe not found:"
Require-File -Path (Join-Path $FfmpegDir "ffprobe.exe") -Message "ffprobe.exe not found:"

# Создаём папки для выходных файлов, если их нет.
Ensure-Directory -Path $Mp3Dir
Ensure-Directory -Path $Mp4Dir

# Нормализуем URL, если он был передан параметром.
$Url = Normalize-Input $Url

# Если URL не был передан параметром — спрашиваем у пользователя.
if (-not $Url) {
    $Url = Normalize-Input (Read-Host "Paste URL")
}

# Если URL всё равно пустой — завершаем работу.
if (-not $Url) {
    Write-Host "URL is empty." -ForegroundColor Red
    exit 1
}

# Спрашиваем режим: mp3 или mp4.
$format = Ask-Format

# Получаем дополнительные аргументы для yt-dlp в зависимости от URL.
$extraArgs = Get-ExtraArgs -DownloadUrl $Url

# Автоопределение названия по title отключено специально ради стабильности.
# Всегда будет использоваться ручной ввод имени или "media".
$suggestedTitle = "media"

if ($format -eq "mp3") {
    # Запрашиваем имя выходного файла.
    $filename = Ask-FileName

    # Полный путь к итоговому mp3-файлу.
    $target = Join-Path $Mp3Dir "$filename.mp3"

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Downloading audio"
    Write-Host "URL:   $Url"
    Write-Host "File:  $target"
    Write-Host "============================================"
    Write-Host ""

    # Общие аргументы для mp3-режима.
    $commonArgs = @()
    $commonArgs += $extraArgs
    $commonArgs += "--ffmpeg-location", $FfmpegDir
    $commonArgs += "-x", "--audio-format", "mp3"
    $commonArgs += "-o", "data/mp3/$filename.mp3"

    # Пытаемся скачать аудио с fallback-стратегиями.
    $result = Invoke-DownloadWithRetry `
        -CommonArgs $commonArgs `
        -PrimarySelector "ba[ext=m4a]/ba/b" `
        -OutputPath $target `
        -Mode "mp3" `
        -Url $Url

    # Если не удалось — выводим ошибку и завершаем работу.
    if (-not $result.Success) {
        Write-Host "Failed to download MP3." -ForegroundColor Red
        exit 1
    }

    # Если всё успешно — выводим путь и использованный режим.
    Write-Host ""
    Write-Host "DONE: $target" -ForegroundColor Green
    Write-Host "USED: $($result.Label)" -ForegroundColor DarkCyan
    exit 0
}

# Если формат не mp3, значит работаем в режиме mp4.
Write-Host ""
Write-Host "Analyzing available formats..." -ForegroundColor Cyan
Write-Host ""

# Аргументы для получения списка доступных форматов.
$formatArgs = @()
$formatArgs += $extraArgs
$formatArgs += "--ffmpeg-location", $FfmpegDir
$formatArgs += "-F"
$formatArgs += $Url

# Вызываем yt-dlp -F и захватываем вывод.
$formatResult = Run-YtDlpCapture -Arguments $formatArgs

# Если yt-dlp не смог получить список форматов — печатаем вывод и завершаемся.
if ($formatResult.ExitCode -ne 0) {
    Write-Host "Failed to get format list." -ForegroundColor Red
    $formatResult.Output | ForEach-Object { Write-Host $_ }
    exit 1
}

# Парсим список форматов на видео и аудио.
$parsed = Parse-Formats -Lines $formatResult.Output

# Показываем сводку по найденным форматам.
Show-FormatsSummary -Parsed $parsed

# Определяем лучший audio id.
$audioId = Get-BestAudioId -AudioFormats $parsed.Audio
if (-not $audioId) {
    Write-Host "Could not determine audio id." -ForegroundColor Red
    exit 1
}

# Подбираем лучшие video id для разных разрешений.
$id1080 = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 1080
$id720  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 720
$id480  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 480
$id360  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 360

# Строим список доступных вариантов выбора качества.
$options = Build-QualityOptions -AudioId $audioId -Id1080 $id1080 -Id720 $id720 -Id480 $id480 -Id360 $id360

# Показываем меню качества и получаем выбор пользователя.
$quality = Ask-QualityModeDynamic -Options $options

# Спрашиваем имя итогового mp4-файла.
$filename = Ask-FileName

# Полный путь к mp4-файлу.
$target = Join-Path $Mp4Dir "$filename.mp4"

Write-Host ""
Write-Host "============================================"
Write-Host "Downloading video"
Write-Host "URL:      $Url"
Write-Host "Quality:  $($quality.Label)"
Write-Host "Selector: $($quality.Selector)"
Write-Host "File:     $target"
Write-Host "============================================"
Write-Host ""

# Общие аргументы для mp4-режима.
$commonArgs = @()
$commonArgs += $extraArgs
$commonArgs += "--ffmpeg-location", $FfmpegDir
$commonArgs += "--merge-output-format", "mp4"
$commonArgs += "-o", "data/mp4/$filename.mp4"

# Пытаемся скачать видео по выбранному селектору и fallback-схемам.
$result = Invoke-DownloadWithRetry `
    -CommonArgs $commonArgs `
    -PrimarySelector $quality.Selector `
    -OutputPath $target `
    -Mode "mp4" `
    -Url $Url

# Если все попытки провалились — завершаем с ошибкой.
if (-not $result.Success) {
    Write-Host "Failed to download MP4." -ForegroundColor Red
    exit 1
}

# Успешное завершение.
Write-Host ""
Write-Host "DONE: $target" -ForegroundColor Green
Write-Host "USED: $($result.Label)" -ForegroundColor DarkCyan