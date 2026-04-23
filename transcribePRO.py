"""transcribe.py — интерактивная транскрибация MP3 через Whisper / faster-whisper.

Функционал:
- умеет брать имя MP3 из аргумента командной строки;
- умеет брать имя модели из аргумента командной строки;
- умеет брать backend из аргумента командной строки;
- если модель/ backend не указаны — предлагает интерактивный выбор;
- если имя файла не указано — спрашивает его через animated_input;
- пытается найти файл либо по прямому пути, либо внутри data/mp3;
- поддерживает два backend:
  1) openai-whisper
  2) faster-whisper
- умеет резать длинное аудио на части через ffmpeg;
- транскрибирует части последовательно и склеивает итоговый текст;
- при нехватке памяти автоматически понижает модель:
  medium -> small -> base;
- умеет сохранять прогресс после каждого чанка;
- умеет продолжать работу после сбоя с уже готовых чанков;
- показывает более понятный прогресс по чанкам и примерный ETA;
- если доступен GPU, умеет использовать его для faster-whisper;
- сохраняет результат в папку data/txt.

Примеры запуска:
- python transcribe.py
- python transcribe.py lesson.mp3
- python transcribe.py lesson.mp3 small
- python transcribe.py lesson.mp3 medium faster-whisper
- python transcribe.py "data/mp3/Golang/GolangLesson_2.mp3" small faster-whisper

Требования:
- Python 3.9+
- установлен ffmpeg / ffprobe
- установлен хотя бы один backend:
  - openai-whisper
  - faster-whisper
"""

# ----------------------------------------------------------------------
# Импорт стандартных модулей
# ----------------------------------------------------------------------

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

# ----------------------------------------------------------------------
# Опциональные импорты backend'ов транскрибации
# ----------------------------------------------------------------------

try:
    import whisper  # type: ignore
except Exception:
    whisper = None

try:
    from faster_whisper import WhisperModel  # type: ignore
except Exception:
    WhisperModel = None

try:
    import torch  # type: ignore
except Exception:
    torch = None

# ----------------------------------------------------------------------
# Папка, где лежат ffmpeg.exe / ffprobe.exe
# ----------------------------------------------------------------------

FFMPEG_DIR = r"D:\DEV\lib\ffmpeg-8.0-essentials_build\bin"

# ----------------------------------------------------------------------
# Значения по умолчанию
# ----------------------------------------------------------------------

MODEL_DEFAULT = os.environ.get("WHISPER_MODEL", "medium")

if os.environ.get("WHISPER_BACKEND"):
    BACKEND_DEFAULT = os.environ["WHISPER_BACKEND"].strip().lower()
else:
    BACKEND_DEFAULT = "faster-whisper" if WhisperModel is not None else "whisper"

# ----------------------------------------------------------------------
# Разрешённые модели и backend'ы
# ----------------------------------------------------------------------

ALLOWED_MODELS = ["tiny", "base", "small", "medium", "large"]
ALLOWED_BACKENDS = ["whisper", "faster-whisper"]

# ----------------------------------------------------------------------
# Порог длины аудио, после которого включаем разбиение
# ----------------------------------------------------------------------

CHUNK_THRESHOLD_MINUTES = 15

# ----------------------------------------------------------------------
# Длина чанка в секундах
# 600 = 10 минут
# ----------------------------------------------------------------------

CHUNK_LENGTH_SECONDS = 600

# ----------------------------------------------------------------------
# Каталог для служебных файлов состояния
# ----------------------------------------------------------------------

STATE_DIR = Path("data/transcribe_state")
STATE_DIR.mkdir(parents=True, exist_ok=True)


def ensure_ffmpeg_in_path() -> None:
    """
    Добавляет папку с ffmpeg в PATH, если ffmpeg/ffprobe ещё не видны системе.
    """

    if shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None:
        return

    if os.path.isdir(FFMPEG_DIR):
        os.environ["PATH"] = FFMPEG_DIR + os.pathsep + os.environ.get("PATH", "")

        ffmpeg_found = shutil.which("ffmpeg") is not None
        ffprobe_found = shutil.which("ffprobe") is not None

        if ffmpeg_found and ffprobe_found:
            print(f"✅ ffmpeg/ffprobe найдены и добавлены в PATH: {FFMPEG_DIR}")
        else:
            print(f"⚠️ Добавили {FFMPEG_DIR} в PATH, но ffmpeg/ffprobe всё ещё не находятся.")
    else:
        print(f"⚠️ Папка с ffmpeg не найдена: {FFMPEG_DIR}")
        print("   Проверь путь к ffmpeg или установи его в систему.")


# ----------------------------------------------------------------------
# При запуске сразу пробуем добавить FFmpeg в PATH
# ----------------------------------------------------------------------

ensure_ffmpeg_in_path()


def animated_input(prompt: str) -> str:
    """
    Красивый ввод с рамкой и псевдо-прогрессбаром.

    :param prompt: Текст подсказки для пользователя.
    :return: Введённая пользователем строка.
    """

    bar = ""

    sys.stdout.write("\n╔══════════════════════════════════════╗\n")
    sys.stdout.write(f"║ {prompt:<36}║\n")
    sys.stdout.write("╚══════════════════════════════════════╝\n")

    for i in range(20):
        bar += "█"
        sys.stdout.write("\r[%-20s] %d%%" % (bar, (i + 1) * 5))
        sys.stdout.flush()
        time.sleep(0.05)

    sys.stdout.write("\n")
    return input("➡ Введите имя: ").strip()


def choose_model_interactive(default_model: str = MODEL_DEFAULT) -> str:
    """
    Интерактивный выбор модели Whisper.

    :param default_model: Модель по умолчанию.
    :return: Имя модели.
    """

    print("\nВыбор модели Whisper:")
    for idx, name in enumerate(ALLOWED_MODELS, start=1):
        marker = " (по умолчанию)" if name == default_model else ""
        print(f"  {idx}. {name}{marker}")

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

        if model in ALLOWED_MODELS:
            print(f"✅ Выбрана модель: {model}")
            return model

        print(f"❌ Модель '{model}' не поддерживается. Разрешено: {', '.join(ALLOWED_MODELS)}")


def choose_backend_interactive(default_backend: str = BACKEND_DEFAULT) -> str:
    """
    Интерактивный выбор backend'а транскрибации.

    :param default_backend: Backend по умолчанию.
    :return: Имя backend'а.
    """

    print("\nВыбор backend для транскрибации:")
    for idx, name in enumerate(ALLOWED_BACKENDS, start=1):
        availability = ""
        if name == "whisper" and whisper is None:
            availability = " (не установлен)"
        elif name == "faster-whisper" and WhisperModel is None:
            availability = " (не установлен)"

        marker = " (по умолчанию)" if name == default_backend else ""
        print(f"  {idx}. {name}{marker}{availability}")

    while True:
        choice = input(
            f"Введите номер backend'а или имя "
            f"({', '.join(ALLOWED_BACKENDS)}), Enter = {default_backend}: "
        ).strip()

        if not choice:
            backend = default_backend
        elif choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(ALLOWED_BACKENDS):
                backend = ALLOWED_BACKENDS[idx - 1]
            else:
                print("❌ Неверный номер. Попробуйте ещё раз.")
                continue
        else:
            backend = choice.lower()

        if backend not in ALLOWED_BACKENDS:
            print(f"❌ Backend '{backend}' не поддерживается.")
            continue

        if backend == "whisper" and whisper is None:
            print("❌ openai-whisper не установлен.")
            continue

        if backend == "faster-whisper" and WhisperModel is None:
            print("❌ faster-whisper не установлен.")
            continue

        print(f"✅ Выбран backend: {backend}")
        return backend


def resolve_audio_path(name: str) -> Optional[Path]:
    """
    Пытается найти аудиофайл:
    1) как путь, переданный пользователем;
    2) как файл в папке data/mp3.

    :param name: Имя файла или путь.
    :return: Path, если файл найден, иначе None.
    """

    p = Path(name)
    if p.exists():
        return p

    candidate = Path("data/mp3") / name
    if candidate.exists():
        return candidate

    return None


def resolve_output_txt_path(name: str, audio_path: Path) -> Path:
    """
    Формирует путь для итогового txt-файла.

    Если пользователь не указал расширение .txt — оно добавляется автоматически.

    :param name: Имя выходного файла.
    :param audio_path: Путь к исходному аудио.
    :return: Полный путь к txt-файлу.
    """

    out_dir = Path("data/txt")
    out_dir.mkdir(parents=True, exist_ok=True)

    clean_name = name.strip()
    if not clean_name:
        clean_name = audio_path.stem

    out_path = Path(clean_name)

    if out_path.parent == Path("."):
        out_path = out_dir / out_path

    out_path.parent.mkdir(parents=True, exist_ok=True)

    if out_path.suffix.lower() != ".txt":
        out_path = out_path.with_suffix(".txt")

    return out_path


def get_audio_duration_seconds(audio_path: Path) -> float:
    """
    Определяет длительность аудиофайла через ffprobe.

    :param audio_path: Путь к аудиофайлу.
    :return: Длительность в секундах.
    :raises RuntimeError: Если ffprobe недоступен или не смог прочитать файл.
    """

    if shutil.which("ffprobe") is None:
        raise RuntimeError("ffprobe не найден. Установи ffmpeg/ffprobe и проверь PATH.")

    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(audio_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        raise RuntimeError(f"ffprobe не смог определить длительность файла: {result.stderr.strip()}")

    duration_str = result.stdout.strip()
    try:
        return float(duration_str)
    except ValueError as exc:
        raise RuntimeError(f"Не удалось преобразовать длительность '{duration_str}' в число.") from exc


def split_audio_if_needed(audio_path: Path, threshold_minutes: int = CHUNK_THRESHOLD_MINUTES) -> list[Path]:
    """
    При необходимости режет длинное аудио на части через ffmpeg.

    Если файл короткий — возвращает список из одного исходного файла.
    Если файл длиннее threshold_minutes — режет на чанки длиной CHUNK_LENGTH_SECONDS.

    :param audio_path: Путь к аудиофайлу.
    :param threshold_minutes: Порог длины, после которого включается разбиение.
    :return: Список путей к чанкам.
    """

    duration_seconds = get_audio_duration_seconds(audio_path)
    duration_minutes = duration_seconds / 60.0

    print(f"⏱ Длительность аудио: {duration_minutes:.1f} мин.")

    if duration_minutes <= threshold_minutes:
        print("✅ Аудио короткое, разбиение на части не требуется.")
        return [audio_path]

    print(f"✂️ Аудио длинное, будет разбито на части по {CHUNK_LENGTH_SECONDS // 60} минут.")

    if shutil.which("ffmpeg") is None:
        raise RuntimeError("ffmpeg не найден. Нельзя разрезать аудио на части.")

    temp_dir = Path(tempfile.mkdtemp(prefix="transcribe_chunks_"))
    out_pattern = temp_dir / "chunk_%03d.mp3"

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(audio_path),
        "-f",
        "segment",
        "-segment_time",
        str(CHUNK_LENGTH_SECONDS),
        "-c",
        "copy",
        str(out_pattern),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg не смог разбить аудио на части: {result.stderr.strip()}")

    chunks = sorted(temp_dir.glob("chunk_*.mp3"))

    if not chunks:
        raise RuntimeError("ffmpeg завершился, но чанки не были созданы.")

    print(f"✅ Создано чанков: {len(chunks)}")
    return chunks


def cleanup_temp_chunks(chunks: list[Path], original_audio_path: Path) -> None:
    """
    Удаляет временные чанки и временную папку, если аудио было разрезано.

    :param chunks: Список путей к чанкам.
    :param original_audio_path: Исходный путь к аудио.
    """

    if len(chunks) == 1 and chunks[0] == original_audio_path:
        return

    try:
        temp_dir = chunks[0].parent
        for chunk in chunks:
            if chunk.exists():
                chunk.unlink()

        if temp_dir.exists():
            temp_dir.rmdir()

        print("🧹 Временные чанки удалены.")
    except Exception as exc:
        print(f"⚠️ Не удалось полностью удалить временные чанки: {exc}")


def build_model_fallback_chain(requested_model: str) -> list[str]:
    """
    Строит цепочку fallback-моделей при нехватке памяти.

    :param requested_model: Исходно выбранная модель.
    :return: Список моделей в порядке попыток.
    """

    requested_model = requested_model.lower()

    fallback_map = {
        "large": ["large", "medium", "small", "base"],
        "medium": ["medium", "small", "base"],
        "small": ["small", "base"],
        "base": ["base"],
        "tiny": ["tiny"],
    }

    return fallback_map.get(requested_model, ["medium", "small", "base"])


def is_memory_error(exc: Exception) -> bool:
    """
    Определяет, похожа ли ошибка на нехватку памяти.

    :param exc: Пойманное исключение.
    :return: True, если ошибка похожа на OOM / нехватку памяти.
    """

    text = str(exc).lower()

    markers = [
        "not enough memory",
        "out of memory",
        "defaultcpuallocator",
        "std::bad_alloc",
        "cannot allocate memory",
        "cuda out of memory",
    ]

    return any(marker in text for marker in markers)


def detect_device_for_faster_whisper() -> tuple[str, str]:
    """
    Определяет, можно ли использовать GPU для faster-whisper.

    Возвращает:
    - ('cuda', 'float16') если доступен CUDA;
    - ('cpu', 'int8') иначе.

    :return: Кортеж (device, compute_type).
    """

    if torch is not None:
        try:
            if torch.cuda.is_available():
                return "cuda", "float16"
        except Exception:
            pass

    return "cpu", "int8"


def load_openai_whisper_model(name: str):
    """
    Загружает модель openai-whisper.

    :param name: Имя модели.
    :return: Объект модели openai-whisper.
    """

    if whisper is None:
        raise RuntimeError("Пакет whisper не установлен.")

    return whisper.load_model(name)


def load_faster_whisper_model(name: str):
    """
    Загружает модель faster-whisper.

    Для CPU используем compute_type='int8', чтобы сократить расход памяти.
    Для CUDA используем float16.

    :param name: Имя модели.
    :return: Объект WhisperModel.
    """

    if WhisperModel is None:
        raise RuntimeError("Пакет faster-whisper не установлен.")

    device, compute_type = detect_device_for_faster_whisper()
    print(f"⚙️ faster-whisper device={device}, compute_type={compute_type}")

    return WhisperModel(name, device=device, compute_type=compute_type)


def transcribe_chunk_openai_whisper(model, chunk_path: Path, language: str = "ru") -> str:
    """
    Транскрибирует один чанк через openai-whisper.

    :param model: Загруженная модель openai-whisper.
    :param chunk_path: Путь к чанку.
    :param language: Язык аудио.
    :return: Текст транскрибации чанка.
    """

    result = model.transcribe(str(chunk_path), language=language)
    return result.get("text", "").strip()


def transcribe_chunk_faster_whisper(model, chunk_path: Path, language: str = "ru") -> str:
    """
    Транскрибирует один чанк через faster-whisper.

    :param model: Загруженная модель faster-whisper.
    :param chunk_path: Путь к чанку.
    :param language: Язык аудио.
    :return: Текст транскрибации чанка.
    """

    segments, _info = model.transcribe(str(chunk_path), language=language)
    texts: list[str] = []

    for segment in segments:
        piece = segment.text.strip()
        if piece:
            texts.append(piece)

    return " ".join(texts).strip()


def build_state_file_path(audio_path: Path, backend: str, requested_model: str) -> Path:
    """
    Строит путь к json-файлу состояния для resume.

    :param audio_path: Исходный аудиофайл.
    :param backend: Выбранный backend.
    :param requested_model: Выбранная модель.
    :return: Путь к state-файлу.
    """

    safe_name = audio_path.stem.replace(" ", "_")
    return STATE_DIR / f"{safe_name}_{backend}_{requested_model}.json"


def load_state(state_path: Path) -> dict:
    """
    Загружает состояние из json-файла, если он существует.

    :param state_path: Путь к state-файлу.
    :return: Словарь состояния.
    """

    if not state_path.exists():
        return {"completed_chunks": {}, "used_model": None}

    try:
        with state_path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"completed_chunks": {}, "used_model": None}


def save_state(state_path: Path, state: dict) -> None:
    """
    Сохраняет текущее состояние транскрибации.

    :param state_path: Путь к state-файлу.
    :param state: Словарь состояния.
    """

    state_path.parent.mkdir(parents=True, exist_ok=True)
    with state_path.open("w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def render_elapsed(seconds: float) -> str:
    """
    Форматирует секунды в HH:MM:SS.

    :param seconds: Число секунд.
    :return: Строка времени.
    """

    seconds = max(0, int(seconds))
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def transcribe_chunks_with_backend(
    chunks: list[Path],
    backend: str,
    requested_model: str,
    language: str = "ru",
    state_path: Optional[Path] = None,
) -> tuple[str, str]:
    """
    Транскрибирует список чанков выбранным backend'ом с авто-fallback по моделям.

    Если происходит ошибка нехватки памяти:
    - пробуем следующую модель из fallback-цепочки.

    Если есть state-файл:
    - пропускаем уже готовые чанки;
    - продолжаем с места остановки.

    :param chunks: Список путей к чанкам.
    :param backend: 'whisper' или 'faster-whisper'.
    :param requested_model: Исходно выбранная модель.
    :param language: Язык аудио.
    :param state_path: Путь к state-файлу для resume.
    :return: Кортеж (итоговый текст, фактически использованная модель).
    """

    model_chain = build_model_fallback_chain(requested_model)
    last_exc: Optional[Exception] = None

    state = {"completed_chunks": {}, "used_model": None}
    if state_path is not None:
        state = load_state(state_path)

    for model_name in model_chain:
        try:
            print(f"\nЗагружаем модель ({backend}: {model_name})...")

            if backend == "whisper":
                model = load_openai_whisper_model(model_name)
            elif backend == "faster-whisper":
                model = load_faster_whisper_model(model_name)
            else:
                raise RuntimeError(f"Неизвестный backend: {backend}")

            print(f"✅ Модель загружена: {backend} / {model_name}")

            total_chunks = len(chunks)
            start_time = time.time()

            for index, chunk_path in enumerate(chunks, start=1):
                chunk_key = str(index)

                if chunk_key in state["completed_chunks"]:
                    print(f"⏩ Чанк {index}/{total_chunks} уже готов, пропускаем.")
                    continue

                print(f"\n📌 Чанк {index}/{total_chunks}: {chunk_path.name}")

                chunk_result_text: Optional[str] = None

                chunk_start = time.time()

                def transcribe_progress():
                    """Показывает простой текстовый индикатор, пока транскрибация чанка не завершится."""
                    nonlocal chunk_result_text
                    dots = ""

                    while chunk_result_text is None:
                        dots += "."
                        if len(dots) > 3:
                            dots = ""

                        elapsed_total = time.time() - start_time
                        completed_count = len(state["completed_chunks"])

                        avg_per_chunk = elapsed_total / max(completed_count, 1) if completed_count > 0 else 0.0
                        remaining = total_chunks - completed_count
                        eta = avg_per_chunk * remaining if avg_per_chunk > 0 else 0.0

                        sys.stdout.write(
                            f"\rTranscribing chunk {index}/{total_chunks}{dots} "
                            f"| elapsed {render_elapsed(elapsed_total)} "
                            f"| eta {render_elapsed(eta)}"
                        )
                        sys.stdout.flush()
                        time.sleep(0.5)

                    sys.stdout.write("\n")

                t = threading.Thread(target=transcribe_progress, daemon=True)
                t.start()

                if backend == "whisper":
                    chunk_result_text = transcribe_chunk_openai_whisper(
                        model=model,
                        chunk_path=chunk_path,
                        language=language,
                    )
                else:
                    chunk_result_text = transcribe_chunk_faster_whisper(
                        model=model,
                        chunk_path=chunk_path,
                        language=language,
                    )

                t.join()

                chunk_elapsed = time.time() - chunk_start
                print(f"✅ Чанк {index}/{total_chunks} готов за {render_elapsed(chunk_elapsed)}")

                # ------------------------------------------------------------------
                # Autosave сразу после завершения чанка
                # ------------------------------------------------------------------
                state["completed_chunks"][chunk_key] = chunk_result_text
                state["used_model"] = model_name

                if state_path is not None:
                    save_state(state_path, state)

            # ----------------------------------------------------------------------
            # Склеиваем итоговый текст в правильном порядке
            # ----------------------------------------------------------------------
            ordered_texts: list[str] = []
            for idx in range(1, total_chunks + 1):
                piece = state["completed_chunks"].get(str(idx), "").strip()
                if piece:
                    ordered_texts.append(piece)

            final_text = "\n\n".join(ordered_texts).strip()
            return final_text, model_name

        except Exception as exc:
            last_exc = exc

            if is_memory_error(exc):
                print(f"\n⚠️ Нехватка памяти на модели '{model_name}'.")
                print("   Пробуем более лёгкую модель...")
                continue

            raise

    raise RuntimeError(
        f"Не удалось завершить транскрибацию. "
        f"Последняя ошибка: {last_exc}"
    )


def main() -> None:
    """
    Основная функция:
    - берёт имя MP3 из аргумента или спрашивает у пользователя;
    - выбирает backend;
    - выбирает модель;
    - при необходимости режет аудио на части;
    - умеет продолжать с места сбоя;
    - транскрибирует все части;
    - сохраняет результат в data/txt.
    """

    args = sys.argv[1:]

    # ------------------------------------------------------------------
    # Аргументы:
    # python transcribe.py audio.mp3 medium faster-whisper
    # ------------------------------------------------------------------
    cli_audio_name = args[0] if len(args) >= 1 else None
    cli_model_name = args[1] if len(args) >= 2 else None
    cli_backend_name = args[2] if len(args) >= 3 else None

    # ---------- Имя аудиофайла ----------

    if cli_audio_name:
        audio_file_name = cli_audio_name
        print(f"\nИспользуем MP3 из аргумента: {audio_file_name}")
    else:
        audio_file_name = animated_input("Введите имя MP3 файла")

    audio_path = resolve_audio_path(audio_file_name)

    if not audio_path:
        print(f"❌ Файл '{audio_file_name}' не найден ни как путь, ни в папке data/mp3.")
        return

    # ---------- Выбор backend ----------

    if cli_backend_name:
        backend_name = cli_backend_name.lower()

        if backend_name not in ALLOWED_BACKENDS:
            print(f"⚠️ Backend '{backend_name}' не поддерживается.")
            backend_name = choose_backend_interactive()
        elif backend_name == "whisper" and whisper is None:
            print("⚠️ Пакет whisper не установлен.")
            backend_name = choose_backend_interactive()
        elif backend_name == "faster-whisper" and WhisperModel is None:
            print("⚠️ Пакет faster-whisper не установлен.")
            backend_name = choose_backend_interactive()
        else:
            print(f"Используем backend из аргумента: {backend_name}")
    else:
        backend_name = choose_backend_interactive()

    # ---------- Выбор модели ----------

    if cli_model_name:
        model_name = cli_model_name.lower()

        if model_name not in ALLOWED_MODELS:
            print(
                f"⚠️ Модель '{model_name}' не поддерживается. "
                f"Будет использована модель по умолчанию."
            )
            model_name = choose_model_interactive()
        else:
            print(f"Используем модель из аргумента: {model_name}")
    else:
        model_name = choose_model_interactive()

    # ---------- Разбиение аудио ----------

    try:
        chunks = split_audio_if_needed(audio_path)
    except Exception as exc:
        print(f"❌ Ошибка при подготовке аудио: {exc}")
        return

    # ---------- Resume state ----------

    state_path = build_state_file_path(audio_path, backend_name, model_name)
    if state_path.exists():
        print(f"🔁 Найден state-файл, будет попытка продолжить работу: {state_path}")

    # ---------- Транскрибация ----------

    print("\nТранскрибируем...")

    try:
        text, used_model = transcribe_chunks_with_backend(
            chunks=chunks,
            backend=backend_name,
            requested_model=model_name,
            language="ru",
            state_path=state_path,
        )
    except Exception as exc:
        print(f"\n❌ Ошибка транскрибации: {exc}")
        cleanup_temp_chunks(chunks, audio_path)
        return

    # ---------- Очистка временных чанков ----------

    cleanup_temp_chunks(chunks, audio_path)

    # ---------- Показ текста ----------

    print("\n" + text)

    # ---------- Имя TXT-файла ----------

    txt_file_name = animated_input("Введите имя текст файла")
    out_file = resolve_output_txt_path(txt_file_name, audio_path)

    with out_file.open("w", encoding="utf-8") as f:
        f.write(text)

    print(f"\n✅ Расшифровка сохранена в {out_file}")
    print(f"✅ Фактически использованная модель: {used_model}")
    print(f"✅ Backend: {backend_name}")

    # ------------------------------------------------------------------
    # После успешного завершения state-файл уже не нужен
    # ------------------------------------------------------------------
    try:
        if state_path.exists():
            state_path.unlink()
            print("🧹 State-файл удалён после успешного завершения.")
    except Exception as exc:
        print(f"⚠️ Не удалось удалить state-файл: {exc}")


# ----------------------------------------------------------------------
# Точка входа в программу
# ----------------------------------------------------------------------
if __name__ == "__main__":
    main()

# ----------------------------------------------------------------------
# Примеры запуска
# ----------------------------------------------------------------------
#
# 1. Интерактивно:
#    python transcribe.py
#
# 2. Файл из аргумента, модель и backend через выбор:
#    python transcribe.py curswork8.mp3
#
# 3. Файл + модель:
#    python transcribe.py curswork8.mp3 small
#
# 4. Файл + модель + backend:
#    python transcribe.py curswork8.mp3 medium faster-whisper
#
# 5. Полный путь к файлу:
#    python transcribe.py "TranscribeUtils/data/mp3/Golang/GolangLesson_2.mp3" small faster-whisper
#
# ----------------------------------------------------------------------
# Что делает этот вариант
# ----------------------------------------------------------------------
#
# - если аудио длинное, режет его на чанки через ffmpeg;
# - транскрибирует чанки по одному, чтобы не упираться в RAM;
# - если модель слишком тяжёлая и памяти не хватает:
#   medium -> small -> base;
# - умеет работать через faster-whisper;
# - если есть GPU и доступен torch.cuda, faster-whisper использует CUDA;
# - сохраняет прогресс после каждого чанка;
# - после сбоя умеет продолжить с уже готовых чанков;
# - сохраняет итоговый текст целиком в один txt.