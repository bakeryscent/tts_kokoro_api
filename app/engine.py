import base64
import hashlib
import os
import re
import threading
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import torch
from kokoro import KPipeline

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
SAMPLE_RATE = 24000

# FP16 inference on CUDA — ~1.5× faster on L4 with near-zero quality loss.
# Off by default on non-CUDA (CPU FP16 is often slower). Disable with KOKORO_FP16=0.
USE_FP16 = DEVICE == "cuda" and os.environ.get("KOKORO_FP16", "1") != "0"

# Cap cache by total bytes (audio payloads dominate size). ~500MB default.
CACHE_MAX_BYTES = int(os.environ.get("KOKORO_CACHE_MAX_BYTES", str(500 * 1024 * 1024)))

LANG_CODES = ("a", "b", "e", "f", "h", "i", "j", "p", "z")

_SAMPLE_VOICE_PER_LANG = {
    "a": "af_bella",
    "b": "bf_emma",
    "e": "ef_dora",
    "f": "ff_siwis",
    "h": "hf_alpha",
    "i": "if_sara",
    "j": "jf_alpha",
    "p": "pf_dora",
    "z": "zf_xiaobei",
}

_CJK_RANGES = (
    (0x3040, 0x30FF),
    (0x4E00, 0x9FFF),
    (0x3400, 0x4DBF),
    (0xF900, 0xFAFF),
    (0xAC00, 0xD7AF),
)


@dataclass
class Word:
    id: int
    start: float
    end: float
    text: str


@dataclass
class SynthesisResult:
    audio_pcm16_base64: str
    duration_seconds: float
    words: List[Word]


_pipelines: Dict[str, KPipeline] = {}
_pipelines_lock = threading.Lock()

_cache: "OrderedDict[str, SynthesisResult]" = OrderedDict()
_pending: Dict[str, threading.Event] = {}
_cache_lock = threading.Lock()
_cache_bytes = 0

_stats = {"hits": 0, "misses": 0, "dedupes": 0, "evictions": 0}


def get_stats() -> Dict[str, Any]:
    with _cache_lock:
        return {
            **_stats,
            "entries": len(_cache),
            "bytes": _cache_bytes,
            "max_bytes": CACHE_MAX_BYTES,
            "pipelines_loaded": sorted(_pipelines.keys()),
            "device": DEVICE,
            "fp16": USE_FP16,
        }


def _cache_key(text: str, voice: str, speed: float, return_timestamps: bool) -> str:
    h = hashlib.sha1(f"{voice}|{speed}|{int(return_timestamps)}|{text}".encode("utf-8"))
    return h.hexdigest()


def _evict_lru():
    # Never evict the sole remaining entry — if a single audio blob exceeds
    # CACHE_MAX_BYTES, we'd rather temporarily exceed the cap than thrash.
    global _cache_bytes
    while len(_cache) > 1 and _cache_bytes > CACHE_MAX_BYTES:
        _, victim = _cache.popitem(last=False)
        _cache_bytes -= len(victim.audio_pcm16_base64)
        _stats["evictions"] += 1


def _pipeline_for(voice: str) -> KPipeline:
    lang = voice[0] if voice and voice[0] in LANG_CODES else "a"
    with _pipelines_lock:
        pipe = _pipelines.get(lang)
        if pipe is not None:
            return pipe
        pipe = KPipeline(lang_code=lang, device=DEVICE)
        if USE_FP16 and getattr(pipe, "model", None) is not None:
            try:
                pipe.model = pipe.model.half()
            except Exception:
                pass
        _pipelines[lang] = pipe
        return pipe


def _float32_to_pcm16_base64(audio: np.ndarray) -> str:
    clipped = np.clip(audio, -1.0, 1.0)
    int16 = (clipped * 32767.0).astype("<i2")
    return base64.b64encode(int16.tobytes()).decode("ascii")


def _extract_aligned_words(result: Any, text: str) -> Optional[List[Word]]:
    tokens = getattr(result, "tokens", None)
    if not tokens:
        return None

    out: List[Word] = []
    cursor = 0

    for tok in tokens:
        chunk = getattr(tok, "whole_match", None) or getattr(tok, "text", None)
        if not chunk:
            continue
        chunk = str(chunk).strip()
        if not chunk:
            continue
        start_ts = getattr(tok, "start_ts", None)
        end_ts = getattr(tok, "end_ts", None)
        if start_ts is None or end_ts is None:
            return None

        idx = text.find(chunk, cursor)
        if idx < 0:
            idx = text.find(chunk)
            if idx < 0:
                continue

        s = float(start_ts)
        e = float(end_ts)
        if out and idx == cursor and text[idx - 1:idx] != " ":
            prev = out[-1]
            out[-1] = Word(id=prev.id, start=prev.start, end=round(e, 4), text=prev.text + chunk)
        else:
            out.append(Word(id=len(out), start=round(s, 4), end=round(e, 4), text=chunk))
        cursor = idx + len(chunk)

    return out if out else None


def _is_cjk_char(c: str) -> bool:
    cp = ord(c)
    return any(lo <= cp <= hi for lo, hi in _CJK_RANGES)


def _estimate_words_by_char_weight(text: str, duration: float) -> List[Word]:
    non_space = sum(1 for c in text if not c.isspace())
    cjk_chars = sum(1 for c in text if _is_cjk_char(c))
    if non_space > 0 and cjk_chars / non_space > 0.3:
        tokens = [c for c in text if not c.isspace() and c.strip()]
    else:
        tokens = re.findall(r"\S+", text)

    if not tokens:
        return []
    weights = [max(1, len(t)) for t in tokens]
    total = sum(weights)
    out: List[Word] = []
    cursor = 0.0
    for i, (t, weight) in enumerate(zip(tokens, weights)):
        slice_dur = duration * (weight / total)
        out.append(Word(id=i, start=round(cursor, 4), end=round(cursor + slice_dur, 4), text=t))
        cursor += slice_dur
    return out


def _synthesize_uncached(text: str, voice: str, speed: float, return_timestamps: bool) -> SynthesisResult:
    pipe = _pipeline_for(voice)
    chunks: List[np.ndarray] = []
    last_result: Any = None

    for item in pipe(text, voice=voice, speed=float(speed), split_pattern=None):
        last_result = item
        if hasattr(item, "audio"):
            audio = item.audio
        elif isinstance(item, tuple) and len(item) >= 3:
            audio = item[2]
        else:
            audio = item
        if hasattr(audio, "detach"):
            audio = audio.detach().to(torch.float32).cpu().numpy()
        chunks.append(np.asarray(audio, dtype=np.float32))

    if not chunks:
        raise RuntimeError("Kokoro produced no audio")
    final = chunks[0] if len(chunks) == 1 else np.concatenate(chunks)
    duration = len(final) / SAMPLE_RATE

    words: List[Word] = []
    if return_timestamps:
        aligned = _extract_aligned_words(last_result, text) if last_result is not None else None
        words = aligned if aligned is not None else _estimate_words_by_char_weight(text, duration)

    return SynthesisResult(
        audio_pcm16_base64=_float32_to_pcm16_base64(final),
        duration_seconds=duration,
        words=words,
    )


def synthesize(
    text: str,
    voice: str,
    speed: float = 1.0,
    return_timestamps: bool = True,
) -> Tuple[SynthesisResult, bool]:
    """Synthesize audio with an LRU cache and in-flight request dedup.

    Returns (result, cache_hit). cache_hit is True on a cache hit or when the
    result came from a de-duplicated in-flight request."""
    global _cache_bytes
    key = _cache_key(text, voice, speed, return_timestamps)

    with _cache_lock:
        if key in _cache:
            _cache.move_to_end(key)
            _stats["hits"] += 1
            return _cache[key], True
        event = _pending.get(key)
        if event is not None:
            wait_event = event
        else:
            wait_event = None
            _pending[key] = threading.Event()

    if wait_event is not None:
        wait_event.wait(timeout=60)
        with _cache_lock:
            if key in _cache:
                _cache.move_to_end(key)
                _stats["dedupes"] += 1
                return _cache[key], True
            # Waiter fell through (computation failed or timed out); take over.
            if key not in _pending:
                _pending[key] = threading.Event()

    with _cache_lock:
        _stats["misses"] += 1

    try:
        result = _synthesize_uncached(text, voice, speed, return_timestamps)
    except Exception:
        with _cache_lock:
            evt = _pending.pop(key, None)
        if evt is not None:
            evt.set()
        raise

    with _cache_lock:
        _cache[key] = result
        _cache_bytes += len(result.audio_pcm16_base64)
        _evict_lru()
        evt = _pending.pop(key, None)
    if evt is not None:
        evt.set()
    return result, False


def preload_all_languages(device: str = "cpu") -> None:
    for lang in LANG_CODES:
        KPipeline(lang_code=lang, device=device)


def warmup_all_languages() -> None:
    for lang in LANG_CODES:
        sample_voice = _SAMPLE_VOICE_PER_LANG.get(lang)
        if not sample_voice:
            continue
        try:
            synthesize("Hello.", sample_voice, speed=1.0, return_timestamps=False)
        except Exception:
            pass
