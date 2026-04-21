# ========================================================================
# AGGRESSIVE WINDOWS CLEANUP
# ========================================================================
#
# Что делает этот скрипт:
#
# Скрипт выполняет расширенную очистку Windows и освобождение места на диске C:.
# Он сочетает автоматические и подтверждаемые пользователем действия.
#
# Основные возможности:
#
# 1. Показывает количество свободного места на диске C: до и после очистки.
#
# 2. Удаляет временные файлы пользователя:
#    - содержимое %TEMP%
#
# 3. Удаляет системенные временные файлы:
#    - C:\Windows\Temp
#
# 4. Очищает кэш Windows Update:
#    - останавливает связанные службы
#    - удаляет загруженные обновления и кэш BITS
#    - запускает службы обратно
#
# 5. Очищает Delivery Optimization cache.
#
# 6. Очищает корзину.
#
# 7. Очищает журналы событий Windows.
#
# 8. Запускает DISM StartComponentCleanup для очистки WinSxS.
#
# 9. Опционально отключает гибернацию и удаляет hiberfil.sys.
#
# 10. Опционально удаляет папку C:\Windows.old.
#
# 11. Опционально очищает папку Prefetch.
#
# 12. Опционально очищает кэши браузеров:
#     - Google Chrome
#     - Microsoft Edge
#     - Mozilla Firefox
#
# 13. Опционально полностью очищает папку Downloads.
#
# 14. Опционально удаляет точки восстановления:
#     - сначала удаляет самую старую
#     - затем может удалить все точки восстановления на диске C:
#
# 15. В конце считает, сколько места удалось освободить,
#     и рекомендует перезагрузить компьютер.
#
# Важные особенности:
#
# - Скрипт работает в "агрессивном" режиме очистки.
# - Часть ошибок намеренно подавляется, чтобы очистка не останавливалась.
# - Некоторые действия потенциально опасны:
#   * очистка Downloads
#   * удаление всех точек восстановления
#   * отключение гибернации
#   * удаление Windows.old
# - Для ряда шагов требуется подтверждение пользователя.
# - Для части операций нужны права администратора.
# ========================================================================

$ErrorActionPreference = "SilentlyContinue"

# ------------------------------------------------------------------------
# Выводит красиво оформленный заголовок секции в консоль
# ------------------------------------------------------------------------
function Write-Section {
    param([string]$Text)

    # Пустая строка для визуального разделения
    Write-Host ""

    # Верхняя линия разделителя
    Write-Host ("=" * 72) -ForegroundColor DarkGray

    # Текст заголовка секции
    Write-Host $Text -ForegroundColor Cyan

    # Нижняя линия разделителя
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------
# Возвращает свободное место на диске C: в гигабайтах
# Если получить данные не удалось — возвращает 0
# ------------------------------------------------------------------------
function Get-FreeSpaceGB {
    try {
        # Получаем информацию о логическом диске C:
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

        # Переводим байты в гигабайты и округляем до 2 знаков
        return [math]::Round($drive.FreeSpace / 1GB, 2)
    }
    catch {
        # В случае ошибки возвращаем 0, чтобы скрипт не остановился
        return 0
    }
}

# ------------------------------------------------------------------------
# Безопасно удаляет всё содержимое указанной папки,
# но саму папку не удаляет
# ------------------------------------------------------------------------
function Remove-ChildItemsSafe {
    param([string]$Path)

    # Если путь не существует — выводим предупреждение и выходим
    if (-not (Test-Path $Path)) {
        Write-Host "Path not found: $Path" -ForegroundColor Yellow
        return
    }

    # Сообщаем, что сейчас очищаем
    Write-Host "Cleaning: $Path"

    # Получаем все элементы внутри папки, включая скрытые,
    # и пытаемся удалить каждый объект отдельно
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            # Удаление рекурсивно и принудительно
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            # Если какой-то объект удалить не удалось — пропускаем его
            Write-Host "Skipped: $($_.FullName)" -ForegroundColor DarkYellow
        }
    }
}

# ------------------------------------------------------------------------
# Очищает кэш Windows Update
# Для этого временно останавливает службы обновлений,
# удаляет содержимое кэша, затем запускает службы обратно
# ------------------------------------------------------------------------
function Clear-WindowsUpdateCache {
    Write-Host "Stopping update services..."

    # Остановка основных служб, связанных с обновлениями Windows
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue
    Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue

    # Очистка папки загруженных обновлений
    Remove-ChildItemsSafe -Path "C:\Windows\SoftwareDistribution\Download"

    # Очистка кэша загрузчика BITS
    Remove-ChildItemsSafe -Path "C:\ProgramData\Microsoft\Network\Downloader"

    Write-Host "Starting update services..."

    # Запуск служб обратно
    Start-Service cryptsvc -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------
# Очищает кэш Delivery Optimization
# Это кэш механизма доставки обновлений Windows
# ------------------------------------------------------------------------
function Clear-DeliveryOptimization {
    Remove-ChildItemsSafe -Path "C:\Windows\SoftwareDistribution\DeliveryOptimization"
    Remove-ChildItemsSafe -Path "C:\Windows\DeliveryOptimization"
}

# ------------------------------------------------------------------------
# Очищает журналы событий Windows
# Проходит по всем логам и пытается очистить каждый
# ------------------------------------------------------------------------
function Clear-EventLogs {
    Write-Host "Clearing Windows event logs..."

    # Получаем список журналов событий
    wevtutil el | ForEach-Object {
        try {
            # Очищаем каждый журнал
            wevtutil cl $_
        }
        catch {
            # Ошибки игнорируются, чтобы процесс не прерывался
        }
    }
}

# ------------------------------------------------------------------------
# Запускает DISM cleanup для очистки компонентного хранилища WinSxS
# Может занять некоторое время
# ------------------------------------------------------------------------
function Run-DismCleanup {
    Write-Host "Running DISM cleanup..."

    # Запускаем dism.exe и ждём завершения процесса
    Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup" -Wait -NoNewWindow
}

# ------------------------------------------------------------------------
# Опционально отключает гибернацию
# Это удаляет системный файл hiberfil.sys и может освободить много места
# ------------------------------------------------------------------------
function Disable-HibernationOptional {
    $answer = Read-Host "Disable hibernation and remove hiberfil.sys? (Y/N)"

    if ($answer -match "^[Yy]") {
        # Отключение гибернации
        powercfg -h off
        Write-Host "Hibernation disabled." -ForegroundColor Green
    }
    else {
        Write-Host "Hibernation unchanged."
    }
}

# ------------------------------------------------------------------------
# Безопасно очищает корзину
# ------------------------------------------------------------------------
function Clear-RecycleBinSafe {
    Write-Host "Clearing Recycle Bin..."

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
    catch {
        # Ошибки игнорируются
    }
}

# ------------------------------------------------------------------------
# Удаляет папку Windows.old, если она существует
# Сначала назначает владение и права, затем удаляет папку
# ------------------------------------------------------------------------
function Remove-WindowsOld {
    $path = "C:\Windows.old"

    # Если папки нет — сообщаем и выходим
    if (-not (Test-Path $path)) {
        Write-Host "Windows.old not found." -ForegroundColor Yellow
        return
    }

    Write-Host "Removing Windows.old..."

    # Назначаем владельца на папку и вложенные объекты
    cmd /c "takeown /F `"$path`" /R /D Y" | Out-Null

    # Выдаём группе Administrators полный доступ
    cmd /c "icacls `"$path`" /grant Administrators:F /T /C" | Out-Null

    # Удаляем папку полностью
    cmd /c "rd /s /q `"$path`"" | Out-Null

    # Проверяем результат удаления
    if (Test-Path $path) {
        Write-Host "Windows.old was not fully removed." -ForegroundColor Red
    }
    else {
        Write-Host "Windows.old removed." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------
# Очищает папку Prefetch
# Prefetch ускоряет запуск приложений и системы,
# поэтому очистка может быть спорной и сделана опциональной
# ------------------------------------------------------------------------
function Clear-Prefetch {
    Remove-ChildItemsSafe -Path "C:\Windows\Prefetch"
}

# ------------------------------------------------------------------------
# Очищает кэши популярных браузеров:
# - Chrome
# - Edge
# - Firefox
#
# Перед очисткой принудительно закрывает браузеры
# ------------------------------------------------------------------------
function Clear-BrowserCaches {
    Write-Host "Closing browsers..."

    # Закрываем процессы браузеров, если они запущены
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue
    Stop-Process -Name firefox -Force -ErrorAction SilentlyContinue

    # Базовые пути профиля пользователя
    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA

    # Основные кэши Chrome и Edge
    $paths = @(
        "$local\Google\Chrome\User Data\Default\Cache",
        "$local\Google\Chrome\User Data\Default\Code Cache",
        "$local\Google\Chrome\User Data\Default\GPUCache",
        "$local\Google\Chrome\User Data\Default\Service Worker\CacheStorage",
        "$local\Microsoft\Edge\User Data\Default\Cache",
        "$local\Microsoft\Edge\User Data\Default\Code Cache",
        "$local\Microsoft\Edge\User Data\Default\GPUCache",
        "$local\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage"
    )

    # Проходим по каждому пути и очищаем содержимое
    foreach ($path in $paths) {
        Remove-ChildItemsSafe -Path $path
    }

    # Пути к профилям Firefox
    $ffLocal = "$local\Mozilla\Firefox\Profiles"
    $ffRoam = "$roaming\Mozilla\Firefox\Profiles"

    # Для каждого каталога профилей Firefox
    foreach ($root in @($ffLocal, $ffRoam)) {
        if (Test-Path $root) {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {

                # Очищаем cache2
                Remove-ChildItemsSafe -Path (Join-Path $_.FullName "cache2")

                # Очищаем startupCache
                Remove-ChildItemsSafe -Path (Join-Path $_.FullName "startupCache")
            }
        }
    }
}

# ------------------------------------------------------------------------
# Полностью очищает папку Downloads текущего пользователя
# Сделано отдельной функцией, так как действие потенциально опасное
# ------------------------------------------------------------------------
function Clear-Downloads {
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    Remove-ChildItemsSafe -Path $downloads
}

# ------------------------------------------------------------------------
# Удаляет точки восстановления
# Сначала автоматически удаляет самую старую,
# затем может удалить все точки восстановления на диске C:
# ------------------------------------------------------------------------
function Remove-OldRestorePoints {
    Write-Host "Deleting oldest restore point..."

    # Удаляем самую старую теневую копию
    cmd /c "vssadmin delete shadows /for=C: /oldest /quiet" | Out-Null

    # Спрашиваем, нужно ли удалить вообще все точки восстановления
    $answer = Read-Host "Delete ALL restore points on drive C:? (Y/N)"

    if ($answer -match "^[Yy]") {
        cmd /c "vssadmin delete shadows /for=C: /all /quiet" | Out-Null
        Write-Host "All restore points deleted." -ForegroundColor Green
    }
    else {
        Write-Host "Only oldest restore point deleted."
    }
}

# ------------------------------------------------------------------------
# Универсальная функция подтверждения действия
# Возвращает $true, если пользователь ввёл Y/y
# ------------------------------------------------------------------------
function Confirm-Step {
    param([string]$Question)

    $answer = Read-Host "$Question (Y/N)"
    return ($answer -match "^[Yy]")
}

# ------------------------------------------------------------------------
# Старт работы скрипта
# ------------------------------------------------------------------------
Write-Section "START AGGRESSIVE WINDOWS CLEANUP"

# Получаем количество свободного места до очистки
$before = Get-FreeSpaceGB
Write-Host "Free space on C: before cleanup: $before GB" -ForegroundColor Green

# ------------------------------------------------------------------------
# 1. Очистка временных файлов пользователя
# ------------------------------------------------------------------------
Write-Section "1. User temp files"
Remove-ChildItemsSafe -Path $env:TEMP

# ------------------------------------------------------------------------
# 2. Очистка системных временных файлов
# ------------------------------------------------------------------------
Write-Section "2. System temp files"
Remove-ChildItemsSafe -Path "C:\Windows\Temp"

# ------------------------------------------------------------------------
# 3. Очистка кэша Windows Update
# ------------------------------------------------------------------------
Write-Section "3. Windows Update cache"
Clear-WindowsUpdateCache

# ------------------------------------------------------------------------
# 4. Очистка Delivery Optimization
# ------------------------------------------------------------------------
Write-Section "4. Delivery Optimization cache"
Clear-DeliveryOptimization

# ------------------------------------------------------------------------
# 5. Очистка корзины
# ------------------------------------------------------------------------
Write-Section "5. Recycle Bin"
Clear-RecycleBinSafe

# ------------------------------------------------------------------------
# 6. Очистка журналов событий
# ------------------------------------------------------------------------
Write-Section "6. Event logs"
Clear-EventLogs

# ------------------------------------------------------------------------
# 7. Очистка WinSxS через DISM
# ------------------------------------------------------------------------
Write-Section "7. WinSxS component cleanup"
Run-DismCleanup

# ------------------------------------------------------------------------
# 8. Опциональное отключение гибернации
# ------------------------------------------------------------------------
Write-Section "8. Optional: disable hibernation"
Disable-HibernationOptional

# ------------------------------------------------------------------------
# 9. Опциональное удаление Windows.old
# ------------------------------------------------------------------------
Write-Section "9. Optional: remove Windows.old"
if (Confirm-Step -Question "Remove C:\Windows.old") {
    Remove-WindowsOld
}
else {
    Write-Host "Skipped Windows.old."
}

# ------------------------------------------------------------------------
# 10. Опциональная очистка Prefetch
# ------------------------------------------------------------------------
Write-Section "10. Optional: clear Prefetch"
if (Confirm-Step -Question "Clear C:\Windows\Prefetch") {
    Clear-Prefetch
}
else {
    Write-Host "Skipped Prefetch."
}

# ------------------------------------------------------------------------
# 11. Опциональная очистка кэшей браузеров
# ------------------------------------------------------------------------
Write-Section "11. Optional: clear browser caches"
if (Confirm-Step -Question "Clear Chrome, Edge and Firefox caches") {
    Clear-BrowserCaches
}
else {
    Write-Host "Skipped browser caches."
}

# ------------------------------------------------------------------------
# 12. Опциональная полная очистка папки Downloads
# ------------------------------------------------------------------------
Write-Section "12. Optional: clear Downloads"
if (Confirm-Step -Question "Clear Downloads folder completely") {
    Clear-Downloads
}
else {
    Write-Host "Skipped Downloads."
}

# ------------------------------------------------------------------------
# 13. Опциональное удаление старых точек восстановления
# ------------------------------------------------------------------------
Write-Section "13. Optional: remove old restore points"
if (Confirm-Step -Question "Remove old restore points") {
    Remove-OldRestorePoints
}
else {
    Write-Host "Skipped restore points."
}

# ------------------------------------------------------------------------
# Подсчёт результата очистки
# ------------------------------------------------------------------------
$after = Get-FreeSpaceGB

# Сколько места освобождено
$freed = [math]::Round(($after - $before), 2)

# ------------------------------------------------------------------------
# Финальный вывод результата
# ------------------------------------------------------------------------
Write-Section "DONE"
Write-Host "Free space on C: after cleanup: $after GB" -ForegroundColor Green
Write-Host "Freed space: $freed GB" -ForegroundColor Cyan
Write-Host ""
Write-Host "Recommended: restart the computer." -ForegroundColor Yellow