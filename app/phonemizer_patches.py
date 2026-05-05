"""Phonemizer hardening — prevents the May 2 2026 crash class.

Background. phonemizer's `BaseWordsMismatch._mismatched_lines` raises
`RuntimeError("number of lines in input and output must be equal")` whenever
the espeak-ng C bridge returns a different number of lines than was sent in.
This happens on certain inputs (mostly mid-sentence language switches and
rare punctuation patterns). The raise propagates out of the kokoro pipeline,
returns 500 to the client — and on May 2 2026, it preceded a hard process
exit on the next request, suggesting espeak's C state was corrupted.

Whatever the post-raise behavior, the raise itself is harmful: the upstream
code path is annotated `# pragma: nocover` (acknowledging it shouldn't
happen) but happens to us anyway. The safe response is to log and skip
mismatch detection for the affected batch, not to abort.

We patch `BaseWordsMismatch._mismatched_lines` once at import time. All
three subclasses (Ignore/Warn/Remove) inherit it, and method lookup is
dynamic, so this affects every existing and future espeak backend.
"""

from __future__ import annotations

import logging
from typing import List, Tuple

_log = logging.getLogger("kokoro-api.phonemizer_patches")
_PATCH_MARKER = "_kokoro_api_safe_patch"


def _safe_mismatched_lines(self) -> List[Tuple[int, int, int]]:
    n_txt = len(self._count_txt)
    n_phn = len(self._count_phn)
    if n_txt != n_phn:
        # The original raises RuntimeError here. We log and return empty
        # so the upstream `process()` call returns its input unchanged.
        _log.warning(
            "phonemizer line-count mismatch suppressed (input=%d, output=%d)",
            n_txt,
            n_phn,
        )
        return []
    return [
        (n, t, p)
        for n, (t, p) in enumerate(zip(self._count_txt, self._count_phn))
        if t != p
    ]


_safe_mismatched_lines._kokoro_api_safe_patch = True  # type: ignore[attr-defined]


def apply() -> bool:
    """Install all phonemizer hardening patches. Idempotent. Returns True
    if any new patch was applied."""
    applied = False
    applied = _apply_words_mismatch_patch() or applied
    applied = _apply_text_to_phonemes_patch() or applied
    return applied


def _apply_words_mismatch_patch() -> bool:
    try:
        from phonemizer.backend.espeak import words_mismatch
    except ImportError:
        _log.warning("phonemizer not importable; skipping words_mismatch patch")
        return False

    cls = words_mismatch.BaseWordsMismatch
    current = cls._mismatched_lines
    if getattr(current, _PATCH_MARKER, False):
        return False

    cls._mismatched_lines = _safe_mismatched_lines  # type: ignore[assignment]
    _log.info("patched phonemizer BaseWordsMismatch._mismatched_lines (no-raise)")
    return True


def _apply_text_to_phonemes_patch() -> bool:
    """Patch `EspeakWrapper.text_to_phonemes` to swallow UnicodeDecodeError.

    Background. espeak-ng's C library occasionally returns a phoneme buffer
    with invalid UTF-8 bytes — observed on 2026-05-05 as `'utf-8' codec can't
    decode byte 0xfa in position 3`. The standard cause is concurrent access
    racing the shared C state (espeak isn't thread-safe). We've also added a
    process-level lock in engine.py to prevent the race; this patch is a
    defensive fallback for any code path the lock doesn't cover.

    Without this patch the UnicodeDecodeError propagates as HTTP 500, and
    enough back-to-back failures push espeak into a state where it calls
    abort() at the C level (SIGABRT, exit 134). With it we log the bad
    line, return an empty result for that fragment, and let the rest of
    the synthesis continue.
    """
    try:
        from phonemizer.backend.espeak import wrapper as _wrapper
    except ImportError:
        _log.warning("phonemizer wrapper not importable; skipping text_to_phonemes patch")
        return False

    cls = _wrapper.EspeakWrapper
    current = cls.text_to_phonemes
    if getattr(current, _PATCH_MARKER, False):
        return False

    def _safe_text_to_phonemes(self, text, tie):
        try:
            return current(self, text, tie)
        except UnicodeDecodeError as e:
            _log.warning(
                "espeak text_to_phonemes UnicodeDecodeError suppressed (text=%r tie=%r): %s",
                text[:80] if isinstance(text, str) else "<non-str>",
                tie,
                str(e)[:160],
            )
            # Return empty string — upstream `_phonemize_aux` builds a list
            # of these and joins them. An empty fragment loses that line's
            # phonemes (silent / wrong audio for that bit) but keeps the
            # rest of the request alive instead of cascading to SIGABRT.
            return ""

    _safe_text_to_phonemes._kokoro_api_safe_patch = True  # type: ignore[attr-defined]
    cls.text_to_phonemes = _safe_text_to_phonemes  # type: ignore[assignment]
    _log.info("patched phonemizer EspeakWrapper.text_to_phonemes (no-raise on UnicodeDecodeError)")
    return True
