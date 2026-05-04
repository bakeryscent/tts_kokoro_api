#!/usr/bin/env bash
# Supervisor for the kokoro uvicorn process. Restarts on any non-zero exit
# (segfault, OOM, unhandled exception) with exponential backoff capped at
# 60s. Resets the backoff if the process ran for >10s — that way a permanent
# startup failure doesn't hot-loop, but a one-off crash recovers in 2s.
#
# Also runs a memory watchdog: if uvicorn's cgroup RSS exceeds
# KOKORO_MEM_RESTART_PCT (default 85%) of the cgroup limit, the watchdog
# SIGTERMs uvicorn so the supervisor restarts it cleanly. Catches the slow
# RSS climb (May 2-4 incident: ~20 GiB/day on a 47 GiB cap) before the
# kernel OOM-kills the process, which is messier and shows as exit 137
# in dashboards.
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

# Memory watchdog config — overridable via env file.
MEM_RESTART_PCT=${KOKORO_MEM_RESTART_PCT:-85}
MEM_CHECK_INTERVAL=${KOKORO_MEM_CHECK_INTERVAL:-30}
MEM_STARTUP_GRACE=${KOKORO_MEM_STARTUP_GRACE:-180}  # skip checks during warmup (~120s)

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

# Best-effort Axiom emit so watchdog events survive container recreation
# (the kokoro Python process's AxiomHandler can't capture supervisor-side
# events). Silent failure on missing creds / network — never blocks.
ship_axiom() {
    local msg=$1 level=${2:-WARN}
    local extra=${3:-}
    if [ -z "${AXIOM_TOKEN:-}" ] || [ -z "${AXIOM_DATASET:-}" ]; then
        return
    fi
    local now_ms
    now_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
    local payload
    payload=$(printf '[{"_time":%s,"level":"%s","service":"kokoro-supervisor","msg":"%s"%s}]' \
        "$now_ms" "$level" "$msg" "${extra:+,$extra}")
    curl -sS --max-time 5 -X POST \
        -H "Authorization: Bearer $AXIOM_TOKEN" \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        "https://api.axiom.co/v1/datasets/$AXIOM_DATASET/ingest" >/dev/null 2>&1 || true
}

# Memory watchdog: read cgroup current/limit, kill child if usage exceeds
# threshold. Skips checks during the warmup grace period so model loading
# doesn't trip a false positive on first start.
mem_watchdog() {
    local pid=$1
    local limit_path current_path limit
    if [ -f /sys/fs/cgroup/memory.max ]; then
        limit_path=/sys/fs/cgroup/memory.max
        current_path=/sys/fs/cgroup/memory.current
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_path=/sys/fs/cgroup/memory/memory.limit_in_bytes
        current_path=/sys/fs/cgroup/memory/memory.usage_in_bytes
    else
        echo "[watchdog] no cgroup memory files found, watchdog disabled"
        return
    fi
    limit=$(cat "$limit_path" 2>/dev/null || echo 0)
    if [ "$limit" = "max" ] || [ -z "$limit" ] || [ "$limit" = "0" ]; then
        echo "[watchdog] no cgroup memory limit set ($limit_path = $limit), watchdog disabled"
        return
    fi
    local threshold=$((limit * MEM_RESTART_PCT / 100))
    echo "[watchdog] active: limit=${limit}B threshold=${threshold}B (${MEM_RESTART_PCT}%) interval=${MEM_CHECK_INTERVAL}s grace=${MEM_STARTUP_GRACE}s"

    sleep "$MEM_STARTUP_GRACE"

    while kill -0 "$pid" 2>/dev/null; do
        local current
        current=$(cat "$current_path" 2>/dev/null || echo 0)
        if [ "$current" -gt "$threshold" ] 2>/dev/null; then
            local pct=$((current * 100 / limit))
            echo "[watchdog] 🚨 RSS ${current}B / ${limit}B = ${pct}% > ${MEM_RESTART_PCT}% — terminating uvicorn pid=$pid"
            ship_axiom "watchdog.memory_restart" "WARN" \
                "\"rss_bytes\":$current,\"limit_bytes\":$limit,\"pct\":$pct,\"threshold_pct\":$MEM_RESTART_PCT,\"pid\":$pid"
            kill -TERM "$pid" 2>/dev/null || true
            # Give uvicorn 10s to drain in-flight requests, then SIGKILL.
            local i=0
            while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                i=$((i + 1))
            done
            kill -KILL "$pid" 2>/dev/null || true
            return
        fi
        sleep "$MEM_CHECK_INTERVAL"
    done
}

# Forward signals to uvicorn (and the watchdog) so docker stop / kill
# works cleanly without leaking background processes.
on_term() {
    echo "[supervisor] received signal, exiting"
    if [ -n "${watchdog_pid:-}" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
    fi
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

    mem_watchdog "$child" &
    watchdog_pid=$!

    wait "$child"
    ec=$?
    child=

    # Reap the watchdog if it's still alive (uvicorn died on its own).
    if [ -n "${watchdog_pid:-}" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    watchdog_pid=

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
