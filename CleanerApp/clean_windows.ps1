# clean_windows.ps1
# Безопасная очистка Windows: временные файлы, кэши обновлений, журналы, компонентное хранилище
#Запусти PowerShell от имени администратора
#
#Выполни:
#Set-ExecutionPolicy Bypass -Scope Process -Force
#.\clean_windows.ps1

$ErrorActionPreference = "SilentlyContinue"

function Write-Section($text) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkGray
}

function Get-FreeSpaceGB {
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    [math]::Round($drive.FreeSpace / 1GB, 2)
}

function Remove-FilesInFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Host "Папка не найдена: $Path" -ForegroundColor Yellow
        return
    }

    Write-Host "Очистка: $Path"
    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            # пропускаем заблокированные системные файлы
        }
    }
}

function Clear-WindowsUpdateCache {
    Write-Host "Остановка служб обновления..."
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue
    Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue

    $paths = @(
        "C:\Windows\SoftwareDistribution\Download",
        "C:\ProgramData\Microsoft\Network\Downloader"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            Write-Host "Очистка: $path"
            Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                }
                catch {
                }
            }
        }
    }

    Write-Host "Запуск служб обновления..."
    Start-Service cryptsvc -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}

function Clear-DeliveryOptimization {
    $path = "C:\Windows\SoftwareDistribution\DeliveryOptimization"
    if (Test-Path $path) {
        Write-Host "Очистка Delivery Optimization: $path"
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
            }
        }
    }
    else {
        Write-Host "Папка Delivery Optimization не найдена." -ForegroundColor Yellow
    }
}

function Clear-EventLogs {
    Write-Host "Очистка журналов событий Windows..."
    wevtutil el | ForEach-Object {
        try {
            wevtutil cl $_
        }
        catch {
        }
    }
}

function Run-DismCleanup {
    Write-Host "Запуск DISM очистки компонентного хранилища..."
    Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup" -Wait -NoNewWindow
}

function Disable-HibernationOptional {
    Write-Host ""
    $answer = Read-Host "Отключить гибернацию и удалить hiberfil.sys? (Y/N)"
    if ($answer -match "^[YyАа]") {
        Write-Host "Отключение гибернации..."
        powercfg -h off
    }
    else {
        Write-Host "Гибернация оставлена включённой."
    }
}

function Clear-RecycleBinSafe {
    Write-Host "Очистка корзины..."
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
    catch {
        # если команда недоступна, просто пропускаем
    }
}

Write-Section "СТАРТ ОЧИСТКИ WINDOWS"

$before = Get-FreeSpaceGB
Write-Host "Свободно на диске C: ДО очистки: $before GB" -ForegroundColor Green

Write-Section "1. Временные файлы пользователя"
Remove-FilesInFolder -Path $env:TEMP

Write-Section "2. Временные системные файлы"
Remove-FilesInFolder -Path "C:\Windows\Temp"

Write-Section "3. Кэш Центра обновления Windows"
Clear-WindowsUpdateCache

Write-Section "4. Delivery Optimization"
Clear-DeliveryOptimization

Write-Section "5. Очистка корзины"
Clear-RecycleBinSafe

Write-Section "6. Журналы событий Windows"
Clear-EventLogs

Write-Section "7. Очистка компонентного хранилища WinSxS"
Run-DismCleanup

Write-Section "8. Опционально: отключение гибернации"
Disable-HibernationOptional

$after = Get-FreeSpaceGB
$freed = [math]::Round(($after - $before), 2)

Write-Section "ГОТОВО"
Write-Host "Свободно на диске C: ПОСЛЕ очистки: $after GB" -ForegroundColor Green
Write-Host "Освобождено места: $freed GB" -ForegroundColor Cyan

Write-Host ""
Write-Host "Рекомендуется перезагрузить компьютер." -ForegroundColor Yellow

#Что этот скрипт не удаляет
#Он не трогает:
#ваши документы
#рабочий стол
#загрузки
#установленные программы
#папку Windows.old