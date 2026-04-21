"""transcribe_1.py — интерактивная транскрибация MP3 через OpenAI Whisper.

Функционал:
- умеет брать имя MP3 из аргумента командной строки;
- умеет брать имя модели из аргумента командной строки;
- если модель не указана — предлагает интерактивный выбор;
- если имя файла не указано — спрашивает его через animated_input;
- пытается найти файл либо по прямому пути, либо внутри data/mp3;
- загружает модель Whisper;
- транскрибирует аудио в текст на русском языке;
- показывает простой индикатор процесса во время транскрибации;
- сохраняет результат в папку data/txt.

Примеры запуска:
- python transcribe_1.py curswork8.mp3
- python transcribe_1.py curswork8.mp3 small
- python transcribe_1.py

Требования:
- Python 3.9+
- установлен пакет whisper
- установлен ffmpeg
- путь к ffmpeg может быть добавлен через FFMPEG_DIR
"""

# умеет брать имя MP3 из аргумента (python transcribe_1.py curswork8.mp3);
# умеет брать имя модели из аргумента (python transcribe_1.py curswork8.mp3 small);
# если модель не указана — даёт интерактивный выбор tiny/base/small/medium/large;
# если аргумент не задан — работает по-старому: спрашивает имя файла через animated_input.

# ----------------------------------------------------------------------
# Импорт стандартных модулей
# ----------------------------------------------------------------------

import os
import sys
import time
import threading
from pathlib import Path
from typing import Optional

# ----------------------------------------------------------------------
# Импорт библиотеки Whisper
# ----------------------------------------------------------------------

import whisper

# ----------------------------------------------------------------------
# Папка, где лежат ffmpeg.exe / ffprobe.exe
# Используется для добавления FFmpeg в PATH
# ----------------------------------------------------------------------

FFMPEG_DIR = r"D:\DEV\lib\ffmpeg-8.0-essentials_build\bin"


def ensure_ffmpeg_in_path() -> None:
    """Добавляет папку с ffmpeg в PATH, если он ещё не виден в системе."""

    # ------------------------------------------------------------------
    # Проверяем, доступен ли ffmpeg уже сейчас.
    # В исходном коде предполагается использование which(),
    # но сам импорт which здесь отсутствует.
    # Логику не меняем, только комментируем.
    # ------------------------------------------------------------------
    if which("ffmpeg") is not None:
        # ffmpeg уже доступен, ничего не делаем
        return

    # Если папка FFmpeg существует — добавляем её в PATH текущего процесса
    if os.path.isdir(FFMPEG_DIR):
        os.environ["PATH"] = FFMPEG_DIR + os.pathsep + os.environ.get("PATH", "")

        # проверим ещё раз
        if which("ffmpeg") is not None:
            print(f"✅ ffmpeg найден и добавлен в PATH: {FFMPEG_DIR}")
        else:
            print(f"⚠️ Добавили {FFMPEG_DIR} в PATH, но ffmpeg всё ещё не находится через which().")
    else:
        print(f"⚠️ Папка с ffmpeg не найдена: {FFMPEG_DIR}")
        print("   Проверь путь к ffmpeg или установи его в систему.")


# ----------------------------------------------------------------------
# При запуске скрипта сразу пробуем добавить FFmpeg в PATH,
# если указанная папка существует
# ----------------------------------------------------------------------
if os.path.isdir(FFMPEG_DIR):
    os.environ["PATH"] = FFMPEG_DIR + os.pathsep + os.environ.get("PATH", "")
else:
    print(f"⚠️ Папка с ffmpeg не найдена: {FFMPEG_DIR}")
    print("   Проверь путь к ffmpeg или установи его в систему.")

# ---------- Configuration ----------
# Значение по умолчанию можно задать через переменную окружения WHISPER_MODEL
# Например: WHISPER_MODEL=medium

# ----------------------------------------------------------------------
# Модель Whisper по умолчанию:
# либо из переменной окружения WHISPER_MODEL,
# либо "medium"
# ----------------------------------------------------------------------
MODEL_DEFAULT = os.environ.get("WHISPER_MODEL", "medium")

# ----------------------------------------------------------------------
# Разрешённые имена моделей
# ----------------------------------------------------------------------
ALLOWED_MODELS = ["tiny", "base", "small", "medium", "large"]


def animated_input(prompt: str) -> str:
    """
    Красивый ввод с рамкой и псевдо-прогрессбаром.

    :param prompt: Текст подсказки для пользователя.
    :return: Строка, введённая пользователем.
    """

    # ------------------------------------------------------------------
    # Переменная для псевдо-прогрессбара
    # ------------------------------------------------------------------
    bar = ""

    # Рисуем рамку и текст подсказки
    sys.stdout.write("\n╔══════════════════════════════════════╗\n")
    sys.stdout.write(f"║ {prompt:<36}║\n")
    sys.stdout.write("╚══════════════════════════════════════╝\n")

    # ------------------------------------------------------------------
    # Имитируем короткий прогресс-бар для красивого UX
    # ------------------------------------------------------------------
    for i in range(20):
        bar += "█"
        sys.stdout.write("\r[%-20s] %d%%" % (bar, (i + 1) * 5))
        sys.stdout.flush()
        time.sleep(0.05)

    sys.stdout.write("\n")

    # После анимации просим пользователя ввести значение
    return input("➡ Введите имя: ")


def choose_model_interactive(default_model: str = MODEL_DEFAULT) -> str:
    """
    Интерактивный выбор модели Whisper.

    :param default_model: Модель по умолчанию, если пользователь ничего не ввёл.
    :return: Имя модели из ALLOWED_MODELS.
    """

    # Выводим список доступных моделей
    print("\nВыбор модели Whisper:")
    for idx, name in enumerate(ALLOWED_MODELS, start=1):
        marker = " (по умолчанию)" if name == default_model else ""
        print(f"  {idx}. {name}{marker}")

    # ------------------------------------------------------------------
    # В цикле ждём корректный ввод:
    # - Enter -> default_model
    # - номер модели
    # - имя модели
    # ------------------------------------------------------------------
    while True:
        choice = input(
            f"Введите номер модели или имя "
            f"({', '.join(ALLOWED_MODELS)}), Enter = {default_model}: "
        ).strip()

        if not choice:
            model = default_model
        elif choice.isdigit():
            idx = int(choice)

            if 1 <= idx <= len(ALLOWED_MODELS):
                model = ALLOWED_MODELS[idx - 1]
            else:
                print("❌ Неверный номер. Попробуйте ещё раз.")
                continue
        else:
            model = choice.lower()

        # Если модель входит в список разрешённых — возвращаем её
        if model in ALLOWED_MODELS:
            print(f"✅ Выбрана модель: {model}")
            return model

        print(f"❌ Модель '{model}' не поддерживается. Разрешено: {', '.join(ALLOWED_MODELS)}")


def resolve_audio_path(name: str) -> Optional[Path]:
    """
    Пытается найти аудиофайл:
    1) как путь, переданный пользователем;
    2) как файл в папке data/mp3.

    :param name: Имя файла или путь.
    :return: Path, если файл найден, иначе None.
    """

    # Сначала пробуем трактовать строку как прямой путь
    p = Path(name)
    if p.exists():
        return p

    # Если по прямому пути файл не найден —
    # ищем его внутри папки data/mp3
    candidate = Path("data/mp3") / name
    if candidate.exists():
        return candidate

    # Если файл нигде не найден — возвращаем None
    return None


def load_whisper_model(name: str) -> whisper.Whisper:
    """
    Обёртка вокруг whisper.load_model.

    :param name: Имя модели (tiny/base/small/medium/large).
    :return: Объект модели Whisper.
    """

    # Просто загружаем модель Whisper по имени
    return whisper.load_model(name)


def main() -> None:
    """
    Основная функция:
    - берёт имя MP3 из аргумента или спрашивает у пользователя;
    - выбирает модель (из аргумента или интерактивно);
    - транскрибирует аудио в текст;
    - сохраняет результат в data/txt.
    """

    # ---------- Аргументы командной строки ----------
    # python transcribe_1.py curswork8.mp3 small

    # ------------------------------------------------------------------
    # Берём все аргументы после имени скрипта
    # ------------------------------------------------------------------
    args = sys.argv[1:]

    # Первый аргумент — имя или путь к аудиофайлу
    cli_audio_name = args[0] if len(args) >= 1 else None

    # Второй аргумент — имя модели
    cli_model_name = args[1] if len(args) >= 2 else None

    # ---------- Имя аудиофайла ----------

    # Если имя файла передано в аргументе — используем его
    if cli_audio_name:
        audio_file_name = cli_audio_name
        print(f"\nИспользуем MP3 из аргумента: {audio_file_name}")
    else:
        # Иначе спрашиваем через красивый animated_input
        audio_file_name = animated_input("Введите имя MP3 файла")

    # Пытаемся найти файл по указанному имени / пути
    audio_path = resolve_audio_path(audio_file_name)

    if not audio_path:
        print(f"❌ Файл '{audio_file_name}' не найден ни как путь, ни в папке data/mp3.")
        return

    # ---------- Выбор модели ----------

    # Если модель передана через аргумент
    if cli_model_name:
        model_name = cli_model_name.lower()

        # Проверяем, входит ли модель в список поддерживаемых
        if model_name not in ALLOWED_MODELS:
            print(
                f"⚠️ Модель '{model_name}' не поддерживается. "
                f"Будет использована модель по умолчанию."
            )
            model_name = choose_model_interactive()
        else:
            print(f"Используем модель из аргумента: {model_name}")
    else:
        # Модель не указана — предлагаем выбор
        model_name = choose_model_interactive()

    # ---------- Загрузка модели ----------

    print(f"\nЗагружаем модель Whisper ({model_name})...")
    model = load_whisper_model(model_name)

    # ---------- Транскрибация с индикатором ----------

    print("\nТранскрибируем...")
    result = None

    def transcribe_progress():
        """Показывает простой текстовый индикатор, пока транскрибация не завершится."""

        nonlocal result
        dots = ""

        # Пока result не заполнен — крутим текстовую анимацию
        while result is None:
            dots += "."
            if len(dots) > 3:
                dots = ""

            sys.stdout.write(f"\rTranscribing{dots} ")
            sys.stdout.flush()
            time.sleep(0.5)

        sys.stdout.write("\n")

    # Запускаем индикатор в отдельном потоке
    t = threading.Thread(target=transcribe_progress, daemon=True)
    t.start()

    # Выполняем транскрибацию аудио.
    # В коде язык жёстко указан как русский.
    result = model.transcribe(str(audio_path), language="ru")

    # Дожидаемся завершения потока-индикатора
    t.join()

    # Извлекаем текст из результата
    text = result.get("text", "")

    # Показываем расшифровку в консоли
    print("\n" + text)

    # ---------- Имя TXT-файла ----------

    # Спрашиваем имя итогового текстового файла
    txt_file_name = animated_input("Введите имя текст файла")

    # Создаём папку data/txt, если её ещё нет
    out_dir = Path("data/txt")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Формируем путь к итоговому файлу
    out_file = out_dir / txt_file_name

    # Записываем текст в UTF-8
    with out_file.open("w", encoding="utf-8") as f:
        f.write(text)

    print(f"\n✅ Расшифровка сохранена в {out_file}")


# ----------------------------------------------------------------------
# Точка входа в программу
# ----------------------------------------------------------------------
if __name__ == "__main__":
    main()

# 📌 Как это теперь запускать
# 1. Самый короткий вариант (имя только из аргумента, модель — через выбор)
# (.venv) D:\PythonProjectExt\VideoAudioTranscript> python transcribe_1.py curswork8.mp3
#  Скрипт возьмёт файл:
# либо curswork8.mp3 из текущей папки,
# либо data/mp3/curswork8.mp3, если первый вариант не найден.
# Затем покажет меню выбора модели (tiny/base/small/medium/large).
#
# 2. Полностью без вопросов: имя файла + модель из аргументов
# (.venv) D:\PythonProjectExt\VideoAudioTranscript> python transcribe_1.py curswork8.mp3 small
# Файл: curswork8.mp3 или data/mp3/curswork8.mp3;
# Модель: small;
# Ничего дополнительно не спрашивает, кроме имени TXT-файла (через красивый animated_input).
#
# 3. Старый режим — всё из интерактива
# (.venv) D:\PythonProjectExt\VideoAudioTranscript> python transcribe_1.py
# Сначала спросит имя MP3 (animated_input);
# затем предложит выбрать модель в меню;
# потом спросит имя TXT для сохранения результата.