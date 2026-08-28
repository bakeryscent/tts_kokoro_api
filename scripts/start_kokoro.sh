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

# Proactive daily restart. The kokoro process leaks ~9 GiB/day, so left alone
# it hits the memory ceiling every ~3 days AT A RANDOM HOUR — on 2026-08-27
# that meant 2.5h of timeouts during a US-evening peak, with all traffic
# falling back to DeepInfra exactly when DeepInfra is busiest (its 429s cluster
# 17:00-01:00 UTC). Restarting on our own schedule, in the calmest window,
# turns that into a ~2 min blip nobody notices.
# Measured 2026-08-28: baseline ~24 GiB after warmup, leak ~1 GiB/h under
# production traffic, cgroup cap 46.6 GiB → only ~15h of runway before the 85%
# threshold. One restart a day is NOT enough; two, spaced ~12h and both inside
# the calm band, keep it well clear and never surprise us at a bad hour.
# KOKORO_DAILY_RESTART_UTC_HOUR takes one hour or a comma-separated list
# (e.g. "04,16"); empty = off.
DAILY_RESTART_HOUR=${KOKORO_DAILY_RESTART_UTC_HOUR:-}
# Never restart a child younger than this — guards against a restart loop
# inside a target hour. Must be shorter than the gap between windows.
DAILY_RESTART_MIN_UPTIME=${KOKORO_DAILY_RESTART_MIN_UPTIME:-14400}  # 4h

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

# Graceful stop: SIGTERM, 10s to drain in-flight requests, then SIGKILL.
terminate_child() {
    local pid=$1
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
}

# Supervision loop for a running child: memory watchdog (kill above the cgroup
# threshold) plus the optional proactive daily restart. Skips checks during the
# warmup grace period so model loading doesn't trip a false positive.
mem_watchdog() {
    local pid=$1
    local started_at=$(date +%s)
    local limit_path current_path limit
    if [ -f /sys/fs/cgroup/memory.max ]; then
        limit_path=/sys/fs/cgroup/memory.max
        current_path=/sys/fs/cgroup/memory.current
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_path=/sys/fs/cgroup/memory/memory.limit_in_bytes
        current_path=/sys/fs/cgroup/memory/memory.usage_in_bytes
    else
        echo "[watchdog] no cgroup memory files found, memory watchdog disabled"
        limit_path=""
        current_path=""
    fi
    limit=0
    if [ -n "$limit_path" ]; then
        limit=$(cat "$limit_path" 2>/dev/null || echo 0)
    fi
    if [ "$limit" = "max" ] || [ -z "$limit" ] || [ "$limit" = "0" ]; then
        echo "[watchdog] no cgroup memory limit set (${limit_path:-none} = ${limit}), memory watchdog disabled"
        limit=0
    fi
    # Normalize the configured hour(s) once into a " 04 16 " lookup string,
    # forcing base 10: "08"/"09" would be parsed as invalid octal by
    # printf/arithmetic. Invalid entries are dropped with a warning.
    local target_hours=""
    if [ -n "$DAILY_RESTART_HOUR" ]; then
        local raw h n
        for raw in ${DAILY_RESTART_HOUR//,/ }; do
            if n=$((10#$raw)) 2>/dev/null && [ "$n" -ge 0 ] && [ "$n" -le 23 ]; then
                h=$(printf '%02d' "$n")
                target_hours="${target_hours}${h} "
            else
                echo "[watchdog] ignoring invalid restart hour '$raw'"
            fi
        done
        [ -n "$target_hours" ] && target_hours=" ${target_hours}"
    fi

    local threshold=0
    [ "$limit" != "0" ] && threshold=$((limit * MEM_RESTART_PCT / 100))
    echo "[watchdog] active: limit=${limit}B threshold=${threshold}B (${MEM_RESTART_PCT}%) interval=${MEM_CHECK_INTERVAL}s grace=${MEM_STARTUP_GRACE}s daily_restart_utc_hours=${target_hours:-off}"

    sleep "$MEM_STARTUP_GRACE"

    while kill -0 "$pid" 2>/dev/null; do
        # Proactive daily restart, in the quiet window, before the leak forces
        # an uncontrolled one at a bad hour.
        if [ -n "$target_hours" ]; then
            local now_h uptime_s
            now_h=$(date -u +%H)
            uptime_s=$(( $(date +%s) - started_at ))
            if [ "${target_hours#* $now_h}" != "$target_hours" ] &&
               [ "$uptime_s" -ge "$DAILY_RESTART_MIN_UPTIME" ]; then
                echo "[watchdog] ⏰ daily restart window (${now_h}:00 UTC, uptime ${uptime_s}s) — terminating uvicorn pid=$pid"
                ship_axiom "watchdog.daily_restart" "INFO" \
                    "\"uptime_s\":$uptime_s,\"hour_utc\":\"$now_h\",\"pid\":$pid"
                terminate_child "$pid"
                return
            fi
        fi

        local current
        current=$(cat "$current_path" 2>/dev/null || echo 0)
        if [ "$threshold" != "0" ] && [ "$current" -gt "$threshold" ] 2>/dev/null; then
            local pct=$((current * 100 / limit))
            echo "[watchdog] 🚨 RSS ${current}B / ${limit}B = ${pct}% > ${MEM_RESTART_PCT}% — terminating uvicorn pid=$pid"
            ship_axiom "watchdog.memory_restart" "WARN" \
                "\"rss_bytes\":$current,\"limit_bytes\":$limit,\"pct\":$pct,\"threshold_pct\":$MEM_RESTART_PCT,\"pid\":$pid"
            terminate_child "$pid"
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
