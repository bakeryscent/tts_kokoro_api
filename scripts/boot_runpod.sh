#!/bin/bash
# Pod boot for kokoro-tts-prod (RunPod Container Start Command).
# Starts the RunPod template services (sshd/nginx), then hands off to the
# repo supervisor: restart with backoff + memory watchdog + Axiom events.
# Deployed copy lives at /workspace/boot_kokoro.sh on the pod; the pod's
# Container Start Command is `bash /workspace/boot_kokoro.sh`.
/start.sh &
export KOKORO_PROJ=/workspace/tts_kokoro_api

# glibc allocator tuning — REQUIRED, do not remove.
#
# Every synthesis allocates several 237-474 kB transient buffers (float32
# tensor -> numpy copies -> int16 -> bytes -> base64). glibc 2.35 starts by
# mmap'ing anything over 128 KiB and munmap's it on free, which would be
# perfect — but _int_free() contains a dynamic ratchet: the first freed chunk
# larger than the current threshold RAISES the threshold to that size (and
# trim_threshold to twice it). One long request (a 24.65s synthesis allocates
# ~2.4 MB) pushes it past every normal buffer, and from then on they are
# served from arena heaps whose freed space is never returned to the OS.
#
# Measured on this pod 2026-08-28, with these unset: ~1.5 MiB of RSS retained
# per request, 2-3 GiB/h, ~12h from a fresh start to the 85% watchdog
# threshold. Setting MMAP/TRIM_THRESHOLD_ explicitly sets glibc's
# no_dyn_threshold flag, which disables the ratchet and pins the behaviour.
#
# These were baked into the repo Dockerfile (commit 37516e5) but production
# runs the stock RunPod image with the /workspace venv, so they never applied.
# PYTHONMALLOC=malloc from that Dockerfile is deliberately NOT carried over:
# it only affects Python's small-object allocator, while the buffers that leak
# are numpy/torch allocations that bypass pymalloc entirely — and routing
# small objects into a 2-arena glibc adds contention for no benefit.
export MALLOC_ARENA_MAX=2
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_TRIM_THRESHOLD_=131072
export MALLOC_TOP_PAD_=131072

# Two restarts a day (leak is ~1 GiB/h → ~15h of runway). 04:00 and 16:00 UTC
# are both in the calm band for the DeepInfra fallback that covers the ~2 min
# gap (712 and 452 429s per 30 days, against ~5,000 in the 19:00-21:00 peak).
export KOKORO_DAILY_RESTART_UTC_HOUR=04,16

exec bash /workspace/tts_kokoro_api/scripts/start_kokoro.sh
