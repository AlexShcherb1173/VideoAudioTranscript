# 🚀 Как использовать
# Сохрани код как merge_videos_auto.py
# Запусти в терминале:
# python merge_videos_auto.py
# Укажи:
# путь к папке с .mp4;
# куда сохранить videos.txt;
# имя итогового файла, например C:\merged\final.mp4.
#
# 🧭 Что делает
# Шаг	Описание
# 🔍	Находит все .mp4 в указанной папке
# 📝	Создаёт videos.txt с их путями
# ⏱	Вычисляет общую длительность всех файлов
# 📊	Показывает реальный прогресс-бар с секундным обновлением
# 🚀	Объединяет файлы без потери качества
# 🧹	После успеха — удаляет videos.txt
# 🕒	Показывает время выполнения
#
# 📋 Пример работы:
# 📁 Введите путь к папке с MP4 видео: C:\Users\User\Videos
# 📄 Введите путь и имя для списка видео (например videos.txt): C:\Users\User\Videos\list.txt
# 🎞 Введите имя итогового видео (например merged.mp4): C:\Users\User\Videos\final.mp4
#
# 📄 Найдено 3 видеофайла:
#   01. intro.mp4
#   02. lesson.mp4
#   03. outro.mp4
#
# ✅ Список видео сохранён в: C:\Users\User\Videos\list.txt
# ⏱ Общая длительность всех видео: ~12 мин
#
# 🚀 Начинаем объединение...
#
# 📥 [████████████████████████████████████████] 100%
# ✅ Успешно объединено: C:\Users\User\Videos\final.mp4

# ----------------------------------------------------------------------
# Импорт модулей
# ----------------------------------------------------------------------

import os                    # Импортирован в исходном коде; напрямую в логике не используется
import subprocess            # Для запуска ffmpeg как внешнего процесса
import re                    # Для разбора строк Duration и time из вывода ffmpeg
import sys                   # Импортирован в исходном коде; напрямую в логике не используется
import time                  # Для замера времени выполнения
from pathlib import Path     # Для удобной работы с путями
from tqdm import tqdm        # Для отображения progress bar


def parse_duration(ffmpeg_output: str):
    """Извлекает общую длительность видео (в секундах)."""

    # ------------------------------------------------------------------
    # Ищем в выводе FFmpeg строку вида:
    # Duration: 00:12:34.56
    # ------------------------------------------------------------------
    match = re.search(r"Duration: (\d+):(\d+):(\d+\.\d+)", ffmpeg_output)

    # Если строка длительности не найдена — возвращаем 0
    if not match:
        return 0

    # Разбиваем найденные часы, минуты и секунды
    h, m, s = match.groups()

    # Переводим всё в секунды
    return int(h) * 3600 + int(m) * 60 + float(s)


def parse_progress_line(line: str):
    """Парсит строку ffmpeg 'time=...' → секунды."""

    # ------------------------------------------------------------------
    # Ищем строку прогресса вида:
    # time=00:01:23.45
    # ------------------------------------------------------------------
    match = re.search(r"time=(\d+):(\d+):(\d+\.\d+)", line)

    # Если time= не найдено — значит строка не подходит
    if not match:
        return None

    # Получаем часы, минуты и секунды
    h, m, s = match.groups()

    # Переводим текущее время прогресса в секунды
    return int(h) * 3600 + int(m) * 60 + float(s)


def ensure_txt_path(path_str: str) -> Path:
    """
    Проверяет, что введён корректный путь к файлу.
    Если ввели только папку, добавляет 'videos.txt'.
    """

    # Убираем возможные внешние кавычки и создаём Path
    p = Path(path_str.strip('"'))

    # ------------------------------------------------------------------
    # Если пользователь ввёл только папку
    # или путь без расширения файла,
    # автоматически добавляем videos.txt
    # ------------------------------------------------------------------
    if p.is_dir() or not p.suffix:
        p = p / "videos.txt"
        print(f"💡 Путь дополнен автоматически → {p}")

    # Создаём родительскую папку при необходимости
    p.parent.mkdir(parents=True, exist_ok=True)

    return p


def main():
    # Заголовок программы
    print("🎬 FFmpeg Video Merger (Auto + Smart Path + Progress + Cleanup)\n")

    # 1️⃣ Папка с видео
    # Запрашиваем путь к каталогу, где лежат .mp4 файлы
    folder = Path(input("📁 Введите путь к папке с MP4 видео: ").strip('"'))

    # Проверяем, существует ли папка
    if not folder.exists():
        print(f"❌ Папка {folder} не найдена.")
        return

    # 2️⃣ Путь для списка видео
    # Пользователь может ввести:
    # - только папку
    # - полный путь к файлу списка
    txt_input = input("📄 Введите путь или имя для списка видео (например data или data/videos.txt): ")
    txt_path = ensure_txt_path(txt_input)

    # 3️⃣ Имя итогового видео
    # Пользователь вводит путь к итоговому mp4
    output_path = Path(input("🎞 Введите имя итогового видео (например merged.mp4): ").strip('"'))

    # Если расширение не .mp4 — принудительно заменяем/добавляем .mp4
    if output_path.suffix.lower() != ".mp4":
        output_path = output_path.with_suffix(".mp4")

    # 4️⃣ Сканирование видео
    # Ищем все .mp4 файлы в папке и сортируем их
    videos = sorted(folder.glob("*.mp4"))

    # Если видео нет — завершаем работу
    if not videos:
        print("⚠️ В папке нет MP4 файлов.")
        return

    # Выводим список найденных файлов
    print(f"\n📄 Найдено {len(videos)} видеофайлов:")
    for i, v in enumerate(videos, 1):
        print(f"  {i:02}. {v.name}")

    # 5️⃣ Создание списка видео
    # Создаём текстовый файл для FFmpeg concat demuxer
    with txt_path.open("w", encoding="utf-8") as f:
        for v in videos:
            f.write(f"file '{v.resolve()}'\n")

    print(f"\n✅ Список видео сохранён в: {txt_path}")

    # 6️⃣ Проверка ffmpeg
    # Проверяем, доступен ли ffmpeg из PATH
    try:
        subprocess.run(["ffmpeg", "-version"], check=True, stdout=subprocess.DEVNULL)
    except Exception:
        print("⚠️ FFmpeg не найден. Добавьте его в PATH или укажите путь вручную.")
        return

    # 7️⃣ Подсчёт длительности
    # Перед слиянием считаем суммарную длительность всех видео
    print("\n🔍 Считаем общую длительность...")
    total_duration = 0

    for video in videos:
        # ffmpeg -i выводит метаданные в stderr,
        # из которых мы извлекаем Duration
        probe = subprocess.run(
            ["ffmpeg", "-i", str(video)],
            stderr=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            text=True
        )
        total_duration += parse_duration(probe.stderr)

    print(f"⏱ Общая длительность: ~{int(total_duration // 60)} мин\n")

    # 8️⃣ Объединение
    # Запускаем ffmpeg concat с отображением прогресса
    print("🚀 Начинаем объединение...\n")
    start_time = time.time()

    # ------------------------------------------------------------------
    # Команда FFmpeg:
    # -f concat      -> режим объединения по списку
    # -safe 0        -> разрешить абсолютные пути
    # -i txt_path    -> файл списка видео
    # -c copy        -> объединение без перекодирования
    # -progress pipe:1 -> отправка прогресса в stdout
    # -nostats       -> меньше лишнего вывода
    # ------------------------------------------------------------------
    cmd = [
        "ffmpeg",
        "-f", "concat",
        "-safe", "0",
        "-i", str(txt_path),
        "-c", "copy",
        "-progress", "pipe:1",
        "-nostats",
        str(output_path)
    ]

    # Запускаем ffmpeg и объединяем stdout + stderr
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    # ------------------------------------------------------------------
    # Создаём progress bar на основе общего времени всех файлов
    # Когда ffmpeg пишет строку time=..., обновляем прогресс
    # ------------------------------------------------------------------
    with tqdm(total=total_duration, unit="sec", ncols=80, colour="cyan") as pbar:
        for line in process.stdout:
            if "time=" in line:
                current_time = parse_progress_line(line)
                if current_time is not None:
                    pbar.n = min(current_time, total_duration)
                    pbar.refresh()

        # Дожидаемся завершения процесса
        process.wait()

        # Принудительно доводим progress bar до конца
        pbar.n = total_duration
        pbar.refresh()

    # Считаем общее время выполнения
    elapsed = time.time() - start_time

    # 9️⃣ Завершение и очистка
    if process.returncode == 0:
        print(f"\n✅ Успешно объединено: {output_path}")
        print(f"🕒 Время выполнения: {elapsed:.1f} сек.")

        # После успешного объединения удаляем временный txt-файл
        try:
            txt_path.unlink()
            print(f"🧹 Временный файл {txt_path.name} удалён.")
        except Exception:
            print(f"⚠️ Не удалось удалить {txt_path}")
    else:
        print(f"\n❌ Ошибка объединения. Проверь логи FFmpeg.")


# ----------------------------------------------------------------------
# Точка входа в программу
# Код ниже выполняется только если файл запущен напрямую
# ----------------------------------------------------------------------
if __name__ == "__main__":
    main()