#!/bin/bash
# Pod boot for kokoro-tts-prod (RunPod Container Start Command).
# Starts the RunPod template services (sshd/nginx), then hands off to the
# repo supervisor: restart with backoff + memory watchdog + Axiom events.
# Deployed copy lives at /workspace/boot_kokoro.sh on the pod; the pod's
# Container Start Command is `bash /workspace/boot_kokoro.sh`.
/start.sh &
export KOKORO_PROJ=/workspace/tts_kokoro_api
exec bash /workspace/tts_kokoro_api/scripts/start_kokoro.sh
