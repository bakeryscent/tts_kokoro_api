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
    """Install the patch. Idempotent. Returns True if newly applied."""
    try:
        from phonemizer.backend.espeak import words_mismatch
    except ImportError:
        _log.warning("phonemizer not importable; skipping patch")
        return False

    cls = words_mismatch.BaseWordsMismatch
    current = cls._mismatched_lines
    if getattr(current, _PATCH_MARKER, False):
        return False

    cls._mismatched_lines = _safe_mismatched_lines  # type: ignore[assignment]
    _log.info("patched phonemizer BaseWordsMismatch._mismatched_lines (no-raise)")
    return True
