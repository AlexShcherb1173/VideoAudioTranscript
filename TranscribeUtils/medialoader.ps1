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
# - передачу URL через параметр -Url
# - ввод URL вручную, если параметр не был передан
# - выбор формата mp3 или mp4
# - анализ доступных форматов видео через yt-dlp -F
# - автоматический подбор аудио- и видеоформатов
# - выбор качества через текстовое меню
# - ручной ввод video id и audio id
# - повторные попытки скачивания с fallback-стратегиями
# - поддержку cookies.txt для YouTube
# - безопасную очистку имени файла от запрещённых символов Windows
#
# Основной сценарий работы:
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
# 3. Получает ссылку:
#    - из параметра -Url
#    - или спрашивает у пользователя
#
# 4. Спрашивает формат:
#    - mp3
#    - mp4
#
# 5. Для mp3:
#    - спрашивает имя выходного файла
#    - скачивает лучший доступный аудиопоток
#    - конвертирует его в mp3
#    - при необходимости применяет fallback
#
# 6. Для mp4:
#    - получает список доступных форматов
#    - парсит аудио и видео потоки
#    - предлагает меню качества
#    - скачивает выбранный видео+аудио поток
#    - объединяет его в mp4
#    - при необходимости применяет fallback
#
# 7. Показывает итог:
#    - путь к сохранённому файлу
#    - какая стратегия скачивания сработала
#
# Особенности:
#
# - Для YouTube добавляется --js-runtimes node
# - Если рядом со скриптом есть cookies.txt, он будет использован
# - Ошибки внешних exe-команд анализируются через $LASTEXITCODE
# - Автоподстановка имени по title отключена для стабильности
# ======================================================================

param(
    [string]$Url
)

# ----------------------------------------------------------------------
# Если внутренняя команда PowerShell завершается ошибкой,
# выполнение скрипта будет остановлено
# ----------------------------------------------------------------------
$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------
# Для внешних .exe-команд не включаем режим,
# при котором ненулевой exit-code превращается в исключение.
# Это позволяет вручную анализировать $LASTEXITCODE.
# ----------------------------------------------------------------------
$PSNativeCommandUseErrorActionPreference = $false

# ----------------------------------------------------------------------
# Настройка UTF-8 для корректной работы с русским текстом и Unicode
# ----------------------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

# ----------------------------------------------------------------------
# Папка, где лежит сам .ps1-скрипт
# ----------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

# ----------------------------------------------------------------------
# Путь к yt-dlp.exe рядом со скриптом
# ----------------------------------------------------------------------
$YtDlp      = Join-Path $ScriptDir "yt-dlp.exe"

# ----------------------------------------------------------------------
# Путь к cookies.txt рядом со скриптом.
# Может использоваться для YouTube.
# ----------------------------------------------------------------------
$CookiesTxt = Join-Path $ScriptDir "cookies.txt"

# ----------------------------------------------------------------------
# Каталог, где находятся ffmpeg.exe и ffprobe.exe
# ----------------------------------------------------------------------
$FfmpegDir  = "D:\DEV\lib\ffmpeg-8.0-essentials_build\bin"

# ----------------------------------------------------------------------
# Каталоги для сохранения mp3 и mp4
# ----------------------------------------------------------------------
$Mp3Dir     = Join-Path $ScriptDir "data\mp3"
$Mp4Dir     = Join-Path $ScriptDir "data\mp4"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Normalize-Input {
    param([string]$Value)

    # Если значение null — возвращаем null без изменений
    if ($null -eq $Value) { return $null }

    # Убираем пробелы по краям и внешние двойные кавычки
    return $Value.Trim().Trim('"')
}

function Ensure-Directory {
    param([string]$Path)

    # Если папки не существует — создаём её
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Require-File {
    param(
        [string]$Path,
        [string]$Message
    )

    # Если обязательный файл/путь не найден —
    # выводим ошибку и завершаем скрипт
    if (-not (Test-Path $Path)) {
        Write-Host "ERROR: $Message" -ForegroundColor Red
        Write-Host "  $Path"
        exit 1
    }
}

function Sanitize-FileName {
    param([string]$Name)

    # Если имя пустое или состоит только из пробелов —
    # возвращаем безопасное имя по умолчанию
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "media"
    }

    # Получаем список недопустимых символов в имени файла Windows
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name

    # Каждый недопустимый символ заменяем на "_"
    foreach ($ch in $invalidChars) {
        $result = $result.Replace($ch, "_")
    }

    # Сжимаем повторные пробелы
    $result = $result -replace '\s+', ' '

    # Убираем пробелы по краям
    $result = $result.Trim()

    # Ограничиваем длину имени файла
    if ($result.Length -gt 120) {
        $result = $result.Substring(0, 120).Trim()
    }

    # Если после очистки имя стало пустым — снова используем media
    if ([string]::IsNullOrWhiteSpace($result)) {
        return "media"
    }

    return $result
}

function Get-ExtraArgs {
    param([string]$DownloadUrl)

    # Базовые аргументы yt-dlp для устойчивого скачивания
    $args = @(
        "--no-update",
        "--retries", "20",
        "--fragment-retries", "20",
        "--socket-timeout", "30",
        "--concurrent-fragments", "4",
        "--throttled-rate", "100K"
    )

    # Для YouTube добавляем node runtime.
    # При наличии cookies.txt подключаем его.
    if ($DownloadUrl -match "youtube\.com|youtu\.be") {
        $args += @("--js-runtimes", "node")
        if (Test-Path $CookiesTxt) {
            $args += @("--cookies", $CookiesTxt)
        }
    }

    return $args
}

function Run-YtDlpCapture {
    param([string[]]$Arguments)

    # Сохраняем текущее поведение PowerShell для внешних команд
    $oldPref = $PSNativeCommandUseErrorActionPreference

    # Временно отключаем режим, где ненулевой код = исключение
    $PSNativeCommandUseErrorActionPreference = $false

    try {
        # Запускаем yt-dlp и объединяем stdout/stderr
        $output = & $YtDlp @Arguments 2>&1
        $code = $LASTEXITCODE

        # Возвращаем и вывод, и код завершения
        return @{
            Output   = $output
            ExitCode = $code
        }
    }
    finally {
        # Восстанавливаем исходную настройку
        $PSNativeCommandUseErrorActionPreference = $oldPref
    }
}

function Show-Header {
    # Печать красивой шапки в консоли
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "DIRECT MEDIA LOADER" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Ask-Format {
    # Бесконечно спрашиваем, пока пользователь не введёт mp3 или mp4
    while ($true) {
        $fmt = Normalize-Input (Read-Host "Enter format (mp3/mp4)")
        if ($fmt -in @("mp3", "mp4")) {
            return $fmt.ToLower()
        }
        Write-Host "Enter only mp3 or mp4." -ForegroundColor Yellow
    }
}

function Ask-FileName {
    # Получаем имя файла у пользователя
    $name = Normalize-Input (Read-Host "Enter output file name without extension")

    # Если пользователь ничего не ввёл — используем media
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "media"
    }

    # Возвращаем очищенное безопасное имя
    return (Sanitize-FileName $name)
}

function Parse-Formats {
    param([string[]]$Lines)

    # Коллекции найденных видео- и аудиоформатов
    $videoFormats = @()
    $audioFormats = @()

    # Разбираем каждую строку вывода yt-dlp -F
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        # Пропускаем пустые строки
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # Нас интересуют только строки, начинающиеся с format id
        if ($trimmed -notmatch '^[0-9A-Za-z_-]+\s') { continue }

        # format id — первый токен в строке
        $id = ($trimmed -split '\s+')[0]

        # Если это строка с audio only
        if ($trimmed -match 'audio only') {
            $audioFormats += [PSCustomObject]@{
                Id          = $id
                Line        = $trimmed
                IsM4a       = ($trimmed -match 'm4a')
                IsAudioOnly = $true
            }
        }
        # Если строка похожа на видеоформат по шаблону 720p или 1920x1080
        elseif ($trimmed -match '([0-9]{3,4})p|([0-9]{3,4})x([0-9]{3,4})') {
            $height = $null

            # Если найдено 720p/1080p — берём высоту из p-нотации
            if ($trimmed -match '([0-9]{3,4})p') {
                $height = [int]$Matches[1]
            }
            # Иначе, если найдено WxH — берём второе число как высоту
            elseif ($trimmed -match '([0-9]{3,4})x([0-9]{3,4})') {
                $height = [int]$Matches[2]
            }

            # Сохраняем информацию о видеоформате
            $videoFormats += [PSCustomObject]@{
                Id          = $id
                Line        = $trimmed
                Height      = $height
                IsMp4       = ($trimmed -match '\bmp4\b')
                IsVideoOnly = ($trimmed -match 'video only')
            }
        }
    }

    # Возвращаем обе коллекции
    return @{
        Video = $videoFormats
        Audio = $audioFormats
    }
}

function Get-BestAudioId {
    param($AudioFormats)

    # Сначала пробуем найти лучший m4a-аудиопоток по битрейту
    $m4a = $AudioFormats |
        Where-Object { $_.IsM4a } |
        Sort-Object {
            if ($_.Line -match '\s([0-9]+)k(\s|$)') { [int]$Matches[1] } else { 0 }
        } -Descending |
        Select-Object -First 1

    if ($m4a) { return $m4a.Id }

    # Если m4a нет — берём просто лучший аудиопоток по битрейту
    $first = $AudioFormats |
        Sort-Object {
            if ($_.Line -match '\s([0-9]+)k(\s|$)') { [int]$Matches[1] } else { 0 }
        } -Descending |
        Select-Object -First 1

    if ($first) { return $first.Id }

    # Если ничего не найдено
    return $null
}

function Get-BestVideoIdByHeight {
    param(
        $VideoFormats,
        [int]$TargetHeight
    )

    # Предпочитаем mp4 video-only не выше заданной высоты
    $preferred = $VideoFormats |
        Where-Object {
            $_.Height -le $TargetHeight -and $_.IsMp4 -and $_.IsVideoOnly
        } |
        Sort-Object Height -Descending |
        Select-Object -First 1

    if ($preferred) { return $preferred.Id }

    # Если такого нет — берём любой формат не выше TargetHeight
    $fallback = $VideoFormats |
        Where-Object { $_.Height -le $TargetHeight } |
        Sort-Object Height -Descending |
        Select-Object -First 1

    if ($fallback) { return $fallback.Id }

    return $null
}

function Show-FormatsSummary {
    param($Parsed)

    # Краткая сводка форматов для пользователя
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

    # Список вариантов, который будет показан пользователю
    $options = @()

    # Пункт "лучшее доступное"
    $options += [PSCustomObject]@{
        MenuKey  = "1"
        Label    = "Best available"
        Selector = "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b"
    }

    $next = 2

    # Добавляем варианты качеств, если они были найдены
    if ($Id1080) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "1080p [video $Id1080 + audio $AudioId]"
            Selector = "$Id1080+$AudioId"
        }
        $next++
    }

    if ($Id720) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "720p [video $Id720 + audio $AudioId]"
            Selector = "$Id720+$AudioId"
        }
        $next++
    }

    if ($Id480) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "480p [video $Id480 + audio $AudioId]"
            Selector = "$Id480+$AudioId"
        }
        $next++
    }

    if ($Id360) {
        $options += [PSCustomObject]@{
            MenuKey  = "$next"
            Label    = "360p [video $Id360 + audio $AudioId]"
            Selector = "$Id360+$AudioId"
        }
        $next++
    }

    # Режим ручного выбора id
    $options += [PSCustomObject]@{
        MenuKey  = "M"
        Label    = "Manual video id + audio id"
        Selector = $null
    }

    return $options
}

function Ask-QualityModeDynamic {
    param($Options)

    # Печатаем меню вариантов качества
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "AVAILABLE DOWNLOAD OPTIONS" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    foreach ($opt in $Options) {
        Write-Host ("{0}. {1}" -f $opt.MenuKey, $opt.Label)
    }

    Write-Host ""

    while ($true) {
        # Читаем выбор пользователя
        $mode = Normalize-Input (Read-Host "Choose option")
        $modeUpper = $mode.ToUpper()

        # Ищем соответствующий пункт в меню
        $selected = $Options | Where-Object { $_.MenuKey.ToUpper() -eq $modeUpper } | Select-Object -First 1

        if ($selected) {
            # Если выбран ручной режим M
            if ($selected.MenuKey.ToUpper() -eq "M") {
                $vid = Normalize-Input (Read-Host "Enter video id")
                $aud = Normalize-Input (Read-Host "Enter audio id (can be empty)")

                # video id обязателен
                if ([string]::IsNullOrWhiteSpace($vid)) {
                    Write-Host "Video id is empty." -ForegroundColor Yellow
                    continue
                }

                # Если audio id пустой — скачиваем только по video id
                if ([string]::IsNullOrWhiteSpace($aud)) {
                    return @{
                        Selector = $vid
                        Label    = "MANUAL $vid"
                    }
                }

                # Иначе возвращаем комбинированный selector
                return @{
                    Selector = "$vid+$aud"
                    Label    = "MANUAL $vid+$aud"
                }
            }

            # Для обычного пункта меню возвращаем выбранный selector
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

    # Прямой запуск yt-dlp:
    # сначала служебные параметры, потом параметры попытки, потом URL
    & $YtDlp @PrefixArgs @AttemptArgs $Url
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

    # Аргументы для более подробного и удобного вывода прогресса
    $prefixArgs = @(
        "--newline",
        "--progress-template",
        "download:%(progress._percent_str)s | %(progress._speed_str)s | ETA %(progress._eta_str)s | %(info.title)s"
    )

    # Формируем набор попыток в зависимости от режима скачивания
    if ($Mode -eq "mp4") {
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

    # Последовательно перебираем все попытки
    for ($i = 0; $i -lt $attempts.Count; $i++) {
        $attemptNo = $i + 1

        Write-Host ""
        Write-Host ("Attempt {0}/{1}: {2}" -f $attemptNo, $attempts.Count, $attempts[$i].Label) -ForegroundColor Cyan
        Write-Host ""

        $null = Invoke-DirectAttempt -PrefixArgs $prefixArgs -AttemptArgs $attempts[$i].Args -Url $Url

        # Успех = код 0 и реальное существование файла на диске
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutputPath)) {
            return @{
                Success = $true
                Label   = $attempts[$i].Label
            }
        }

        Write-Host ""
        Write-Host "Attempt failed." -ForegroundColor Yellow

        # Если попытка не последняя — немного ждём и продолжаем
        if ($attemptNo -lt $attempts.Count) {
            Write-Host "Retrying with fallback..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }

    # Если все попытки закончились неудачей
    return @{
        Success = $false
        Label   = "All attempts exhausted"
    }
}

# ------------------------------------------------------------
# Prepare
# ------------------------------------------------------------

# Показываем шапку
Show-Header

# Проверяем наличие обязательных файлов
Require-File -Path $YtDlp -Message "yt-dlp.exe not found next to script:"
Require-File -Path (Join-Path $FfmpegDir "ffmpeg.exe") -Message "ffmpeg.exe not found:"
Require-File -Path (Join-Path $FfmpegDir "ffprobe.exe") -Message "ffprobe.exe not found:"

# Создаём папки назначения
Ensure-Directory -Path $Mp3Dir
Ensure-Directory -Path $Mp4Dir

# Нормализуем URL, если он был передан как параметр
$Url = Normalize-Input $Url

# Если параметр не был передан — спрашиваем URL у пользователя
if (-not $Url) {
    $Url = Normalize-Input (Read-Host "Paste URL")
}

# Если ссылка всё ещё пустая — завершаем скрипт
if (-not $Url) {
    Write-Host "URL is empty." -ForegroundColor Red
    exit 1
}

# Спрашиваем формат: mp3 или mp4
$format = Ask-Format

# Получаем дополнительные аргументы yt-dlp для конкретного URL
$extraArgs = Get-ExtraArgs -DownloadUrl $Url

# auto-title intentionally disabled for stability
$suggestedTitle = "media"

if ($format -eq "mp3") {
    # Получаем имя файла и итоговый путь
    $filename = Ask-FileName
    $target = Join-Path $Mp3Dir "$filename.mp3"

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Downloading audio"
    Write-Host "URL:   $Url"
    Write-Host "File:  $target"
    Write-Host "============================================"
    Write-Host ""

    # Общие аргументы для режима mp3
    $commonArgs = @()
    $commonArgs += $extraArgs
    $commonArgs += "--ffmpeg-location", $FfmpegDir
    $commonArgs += "-x", "--audio-format", "mp3"
    $commonArgs += "-o", "data/mp3/$filename.mp3"

    # Запускаем скачивание аудио с fallback-попытками
    $result = Invoke-DownloadWithRetry `
        -CommonArgs $commonArgs `
        -PrimarySelector "ba[ext=m4a]/ba/b" `
        -OutputPath $target `
        -Mode "mp3" `
        -Url $Url

    # Если скачать не удалось — завершаем с ошибкой
    if (-not $result.Success) {
        Write-Host "Failed to download MP3." -ForegroundColor Red
        exit 1
    }

    # Успешное завершение для mp3
    Write-Host ""
    Write-Host "DONE: $target" -ForegroundColor Green
    Write-Host "USED: $($result.Label)" -ForegroundColor DarkCyan
    exit 0
}

# Если формат не mp3, значит работаем в режиме mp4
Write-Host ""
Write-Host "Analyzing available formats..." -ForegroundColor Cyan
Write-Host ""

# Формируем аргументы для yt-dlp -F
$formatArgs = @()
$formatArgs += $extraArgs
$formatArgs += "--ffmpeg-location", $FfmpegDir
$formatArgs += "-F"
$formatArgs += $Url

# Получаем и захватываем список форматов
$formatResult = Run-YtDlpCapture -Arguments $formatArgs

# Если yt-dlp не смог вернуть список форматов — печатаем ошибку и вывод
if ($formatResult.ExitCode -ne 0) {
    Write-Host "Failed to get format list." -ForegroundColor Red
    $formatResult.Output | ForEach-Object { Write-Host $_ }
    exit 1
}

# Парсим форматы и показываем краткую сводку
$parsed = Parse-Formats -Lines $formatResult.Output
Show-FormatsSummary -Parsed $parsed

# Получаем лучший audio id
$audioId = Get-BestAudioId -AudioFormats $parsed.Audio
if (-not $audioId) {
    Write-Host "Could not determine audio id." -ForegroundColor Red
    exit 1
}

# Автоматически подбираем лучшие video id по целевым разрешениям
$id1080 = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 1080
$id720  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 720
$id480  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 480
$id360  = Get-BestVideoIdByHeight -VideoFormats $parsed.Video -TargetHeight 360

# Строим меню выбора качества
$options = Build-QualityOptions -AudioId $audioId -Id1080 $id1080 -Id720 $id720 -Id480 $id480 -Id360 $id360
$quality = Ask-QualityModeDynamic -Options $options

# Получаем имя файла и полный путь к выходному mp4
$filename = Ask-FileName
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

# Общие аргументы для режима mp4
$commonArgs = @()
$commonArgs += $extraArgs
$commonArgs += "--ffmpeg-location", $FfmpegDir
$commonArgs += "--merge-output-format", "mp4"
$commonArgs += "-o", "data/mp4/$filename.mp4"

# Пытаемся скачать mp4 по выбранному selector + fallback
$result = Invoke-DownloadWithRetry `
    -CommonArgs $commonArgs `
    -PrimarySelector $quality.Selector `
    -OutputPath $target `
    -Mode "mp4" `
    -Url $Url

# Если все попытки провалились — завершаем с ошибкой
if (-not $result.Success) {
    Write-Host "Failed to download MP4." -ForegroundColor Red
    exit 1
}

# Успешное завершение
Write-Host ""
Write-Host "DONE: $target" -ForegroundColor Green
Write-Host "USED: $($result.Label)" -ForegroundColor DarkCyan