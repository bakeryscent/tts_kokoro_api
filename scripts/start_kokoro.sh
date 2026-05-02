#!/usr/bin/env bash
# Supervisor for the kokoro uvicorn process. Restarts on any non-zero exit
# (segfault, OOM, unhandled exception) with exponential backoff capped at
# 60s. Resets the backoff if the process ran for >10s — that way a permanent
# startup failure doesn't hot-loop, but a one-off crash recovers in 2s.
#
# Works in two layouts:
#   - inside the Docker image: WORKDIR=/app, system Python (no venv)
#   - on the manually-deployed RunPod: /workspace/tts_kokoro_api with .venv
# Override via KOKORO_PROJ env var (defaults to /app).
#
# /etc/kokoro.env is sourced first if present. Inside the Docker image, env
# vars come from the container template — no env file needed.
set -u

# Source env file FIRST so KOKORO_PROJ + secrets are available below.
ENV_FILE=${KOKORO_ENV_FILE:-/etc/kokoro.env}
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

PROJ=${KOKORO_PROJ:-/app}
LOG_DIR=${KOKORO_LOG_DIR:-/var/log/kokoro}
LOG=$LOG_DIR/kokoro.log
mkdir -p "$LOG_DIR"

# Re-exec with all output appended to the log so subsequent failures are captured.
exec >>"$LOG" 2>&1

# Pick uvicorn: prefer venv binary if present, otherwise rely on PATH.
if [ -x "$PROJ/.venv/bin/uvicorn" ]; then
    UVICORN="$PROJ/.venv/bin/uvicorn"
elif command -v uvicorn >/dev/null 2>&1; then
    UVICORN=$(command -v uvicorn)
else
    echo "[supervisor] FATAL: uvicorn not found in $PROJ/.venv/bin or PATH"
    exit 127
fi

cd "$PROJ"

# Forward signals to uvicorn so docker stop / kill works cleanly.
on_term() {
    echo "[supervisor] received signal, exiting"
    if [ -n "${child:-}" ] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    exit 0
}
trap on_term TERM INT

backoff=2
while true; do
    started=$(date -u +%FT%TZ)
    ts0=$(date +%s)
    echo "[supervisor] starting uvicorn at $started (proj=$PROJ backoff=${backoff}s)"

    "$UVICORN" app.main:app \
        --host 0.0.0.0 --port 8080 --workers 1 \
        --log-level info --timeout-keep-alive 30 &
    child=$!
    wait "$child"
    ec=$?
    child=

    ts1=$(date +%s)
    uptime=$((ts1 - ts0))
    echo "[supervisor] uvicorn exited code=${ec} after ${uptime}s"

    if [ "$uptime" -lt 10 ]; then
        backoff=$((backoff * 2))
        [ "$backoff" -gt 60 ] && backoff=60
    else
        backoff=2
    fi
    echo "[supervisor] sleeping ${backoff}s before restart"
    sleep "$backoff"
done
