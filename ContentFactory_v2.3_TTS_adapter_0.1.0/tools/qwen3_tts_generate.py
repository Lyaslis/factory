#!/usr/bin/env python3
"""Standalone Qwen3-TTS adapter for ContentFactory 2.3.

Uses the user's existing Qwen3-TTS virtual environment and the model directory
managed by the Qwen3-TTS GUI. It intentionally does not modify ContentFactory
JSON/timeline files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate one continuous WAV from a ContentFactory script using Qwen3-TTS CustomVoice."
    )
    parser.add_argument("--model-id", default="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
    parser.add_argument("--model-path", type=Path, required=True,
                        help="Existing local model directory created by Qwen3-TTS GUI")
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--dtype", choices=("float16", "bfloat16", "float32"), default="float16")
    parser.add_argument("--attention", choices=("sdpa", "default"), default="sdpa")
    parser.add_argument("--text-file", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--speaker")
    parser.add_argument("--language", default="Russian")
    parser.add_argument("--instruct", default=None)
    parser.add_argument("--list-speakers", action="store_true")
    return parser.parse_args()


def validate_model_directory(model_path: Path) -> Path:
    """Validate the GUI-managed local model folder before importing/loading weights."""
    model_path = model_path.expanduser().resolve()
    if not model_path.is_dir():
        raise FileNotFoundError(
            "Локальная папка модели Qwen3-TTS не найдена: "
            f"{model_path}. Укажи правильный -QwenRoot; ожидается папка "
            "models\\Qwen---Qwen3-TTS-12Hz-1.7B-CustomVoice."
        )

    required = {
        "config.json": model_path / "config.json",
        "model.safetensors": model_path / "model.safetensors",
        "speech_tokenizer": model_path / "speech_tokenizer",
    }
    missing = [name for name, path in required.items() if not path.exists()]
    if missing:
        raise FileNotFoundError(
            f"Папка модели найдена, но отсутствуют компоненты: {', '.join(missing)}. "
            f"Путь: {model_path}"
        )
    if not (model_path / "speech_tokenizer").is_dir():
        raise FileNotFoundError(
            f"speech_tokenizer существует, но это не папка: {model_path / 'speech_tokenizer'}"
        )
    return model_path


def load_model(args: argparse.Namespace):
    # Use the exact local_dir used by qwen3_tts_gui_app.py's ensure_model_directory().
    # HF offline mode is retained as a guard against accidental downloads.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    model_path = validate_model_directory(args.model_path)

    import torch
    from qwen_tts import Qwen3TTSModel

    if not torch.cuda.is_available() and args.device.startswith("cuda"):
        raise RuntimeError(
            "CUDA недоступна в этом Python-окружении. Проверь PyTorch/CUDA до запуска TTS."
        )

    dtype_map = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }
    attention = "sdpa" if args.attention == "sdpa" else None

    load_kwargs: dict[str, Any] = {
        "device_map": args.device,
        "dtype": dtype_map[args.dtype],
        "attn_implementation": attention,
        "trust_remote_code": False,
    }

    print(f"[TTS] Локальная модель: {model_path}", flush=True)
    print(
        f"[TTS] device_map={args.device}, dtype={args.dtype}, "
        f"attention={args.attention}, offline=True",
        flush=True,
    )

    try:
        # This mirrors the GUI: Qwen3TTSModel.from_pretrained(cache_dir, ...),
        # where cache_dir is the local_dir returned by ensure_model_directory().
        model = Qwen3TTSModel.from_pretrained(str(model_path), **load_kwargs)
    except Exception as first_error:
        error_text = str(first_error).casefold()
        sdpa_related = any(
            marker in error_text
            for marker in (
                "sdpa",
                "scaled_dot_product",
                "attn_implementation",
                "attention implementation",
            )
        )
        if attention is None or not sdpa_related:
            raise

        print(
            "[TTS] Ошибка явно связана с SDPA; повторяю загрузку с attention по умолчанию. "
            f"Причина: {type(first_error).__name__}: {first_error}",
            file=sys.stderr,
            flush=True,
        )
        import gc

        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        load_kwargs["attn_implementation"] = None
        model = Qwen3TTSModel.from_pretrained(str(model_path), **load_kwargs)

    return model, torch, model_path


def main() -> int:
    args = parse_args()

    if not args.list_speakers:
        if args.text_file is None or args.output is None:
            raise SystemExit("Для синтеза обязательны --text-file и --output.")
        if not args.speaker:
            raise SystemExit("Для синтеза укажи --speaker. Список голосов: --list-speakers.")
        if not args.text_file.is_file():
            raise SystemExit(f"Файл сценария не найден: {args.text_file}")

    model, torch, model_path = load_model(args)
    speakers = model.get_supported_speakers() or []
    languages = model.get_supported_languages() or []

    if args.list_speakers:
        print("Поддерживаемые голоса:")
        for speaker in speakers:
            print(f"  - {speaker}")
        print("Поддерживаемые языки:")
        for language in languages:
            print(f"  - {language}")
        return 0

    speaker_match = next(
        (str(item) for item in speakers if str(item).casefold() == args.speaker.casefold()),
        None,
    )
    if speaker_match is None:
        raise SystemExit(
            f"Голос '{args.speaker}' не найден. Доступные голоса: {', '.join(map(str, speakers))}"
        )

    language_match = next(
        (str(item) for item in languages if str(item).casefold() == args.language.casefold()),
        None,
    )
    if language_match is None:
        raise SystemExit(
            f"Язык '{args.language}' не найден. Доступные языки: {', '.join(map(str, languages))}"
        )

    text = args.text_file.read_text(encoding="utf-8-sig").strip()
    if not text:
        raise SystemExit(f"Файл сценария пуст: {args.text_file}")

    word_count = len(re.findall(r"\b[\wЁёА-Яа-я-]+\b", text, flags=re.UNICODE))
    text_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
    output_path = args.output.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(
        f"[TTS] Синтезирую: {word_count} слов, голос={speaker_match}, "
        f"язык={language_match}",
        flush=True,
    )
    started = time.perf_counter()
    with torch.inference_mode():
        wavs, sample_rate = model.generate_custom_voice(
            text=text,
            speaker=speaker_match,
            language=language_match,
            instruct=args.instruct or None,
        )
    generation_seconds = time.perf_counter() - started

    if not wavs:
        raise RuntimeError("Qwen3-TTS вернул пустой список аудиодорожек.")

    import numpy as np
    import soundfile as sf

    audio = np.asarray(wavs[0], dtype=np.float32)
    if audio.size == 0:
        raise RuntimeError("Qwen3-TTS вернул пустой аудиомассив.")
    if not np.isfinite(audio).all():
        raise RuntimeError("В аудиомассиве обнаружены NaN или Inf; WAV не сохранён.")
    if sample_rate <= 0:
        raise RuntimeError(f"Некорректная частота дискретизации: {sample_rate}")

    # Keep the model's actual level; do not normalize or compress at this stage.
    sf.write(str(output_path), audio, int(sample_rate), subtype="PCM_24", format="WAV")
    saved_audio, saved_sample_rate = sf.read(str(output_path), dtype="float32", always_2d=True)

    duration_seconds = float(saved_audio.shape[0] / saved_sample_rate)
    channels = int(saved_audio.shape[1])
    peak = float(np.max(np.abs(saved_audio))) if saved_audio.size else 0.0
    metadata = {
        "adapter": "ContentFactory-Qwen3TTS",
        "adapter_version": "0.1.2",
        "model_id": args.model_id,
        "model_path": str(model_path),
        "speaker": speaker_match,
        "language": language_match,
        "instruct": args.instruct or "",
        "device": args.device,
        "dtype": args.dtype,
        "attention_requested": args.attention,
        "text_file": str(args.text_file.resolve()),
        "text_sha256": text_hash,
        "word_count": word_count,
        "audio_file": str(output_path),
        "sample_rate_hz": int(saved_sample_rate),
        "channels": channels,
        "duration_seconds": round(duration_seconds, 6),
        "peak_dbfs": round(20.0 * __import__("math").log10(max(peak, 1e-9)), 3),
        "generation_seconds": round(generation_seconds, 3),
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "timeline_updated": False,
    }
    metadata_path = output_path.with_name("voice_metadata.json")
    temporary_metadata = metadata_path.with_suffix(".json.tmp")
    temporary_metadata.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary_metadata.replace(metadata_path)

    print(f"[TTS] WAV: {output_path}")
    print(f"[TTS] Длительность: {duration_seconds:.3f} с")
    print(f"[TTS] Частота: {saved_sample_rate} Hz; каналов: {channels}; peak: {metadata['peak_dbfs']} dBFS")
    print(f"[TTS] Метаданные: {metadata_path}")
    print("[TTS] Таймлайн не изменялся.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("[TTS] Прервано пользователем.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[TTS] ОШИБКА: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
