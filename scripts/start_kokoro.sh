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
# Never restart a child younger than this. Its ONLY job is to stop a restart
# loop inside a target hour; the "one restart per window" marker below is what
# actually enforces once-per-window, so this can be short.
#
# It used to be 4h, and that silently disabled the scheduled restart entirely
# (2026-09-06). The memory watchdog now fires more than once a day, and it
# happened to land at ~03:45 — minutes before the 04:00 window. Every scheduled
# restart therefore saw a child a few minutes old and skipped it, so 04:00 had
# not fired since 31 August; on 6 September a second memory kill at 14:11 took
# out the 16:00 window too. The emergency restart was crowding out the planned
# one, which is exactly backwards: the planned restart exists to prevent the
# emergency.
DAILY_RESTART_MIN_UPTIME=${KOKORO_DAILY_RESTART_MIN_UPTIME:-600}  # 10 min

# HARD CAP on child age, and the real guarantee here: unlike a clock window it
# cannot be skipped, crowded out or drifted past, because it depends on nothing
# but the child's own age. With the leak at ~1-1.5 GiB/h over a ~22 GiB
# baseline and an 85% threshold on a 46 GiB cgroup, 8h holds RSS around 34 GiB
# (~73%) and the memory watchdog should never fire again in normal operation —
# it goes back to being the safety net it was meant to be. Deliberately LONGER
# than the spacing of the scheduled windows (6h), so in steady state the window
# is what restarts us, at a predictable hour, and this only takes over when a
# window is missed.
#
# Why this matters more than it used to: between 24 and 28 August the router
# was flipped and the pod went from roughly half the synthesis traffic to
# 99.4% of it. DeepInfra now serves ~700 requests/day, so the fallback that
# used to absorb these events is no longer sized for them — at the ~70k/day it
# handled in early August it was answering "429 Model busy" (54 failed exports
# between 3 and 18 August). An uncontrolled kill at peak is now far more
# expensive than four planned ~2 min blips.
# 0 disables.
MAX_UPTIME=${KOKORO_MAX_UPTIME:-28800}  # 8h

# How long uvicorn gets to finish in-flight requests after SIGTERM. A single
# synthesis can run ~25s (measured: one 24.65s request), so the previous
# hardcoded 10s cut long generations off mid-flight and turned a planned
# restart into client-visible timeouts.
DRAIN_TIMEOUT=${KOKORO_DRAIN_TIMEOUT:-45}

# Remembers the last scheduled window we acted on ("YYYY-MM-DDTHH"), so a
# window fires exactly once even across child restarts. Survives in the log
# dir, which outlives any individual uvicorn process.
WINDOW_MARKER=$LOG_DIR/.last_scheduled_restart

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

# Graceful stop: SIGTERM, then up to DRAIN_TIMEOUT seconds for uvicorn to
# finish what it is already serving before SIGKILL. Uvicorn stops accepting new
# connections as soon as it gets the TERM, so callers fail over to DeepInfra
# immediately while in-flight generations are allowed to complete.
terminate_child() {
    local pid=$1
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt "$DRAIN_TIMEOUT" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "[supervisor] pid=$pid still alive after ${DRAIN_TIMEOUT}s drain — SIGKILL"
        ship_axiom "watchdog.drain_timeout" "WARN" \
            "\"drain_timeout_s\":$DRAIN_TIMEOUT,\"pid\":$pid"
        kill -KILL "$pid" 2>/dev/null || true
    else
        echo "[supervisor] pid=$pid drained in ${i}s"
    fi
}

# If we are restarting for ANY reason while inside a scheduled window, claim
# that window. Without this, a max-uptime or memory restart at 10:02 would be
# followed by the 10:00 window firing again ~10 minutes later: two restarts
# where one was wanted.
stamp_window_if_target() {
    [ -n "${target_hours:-}" ] || return 0
    local now_h
    now_h=$(date -u +%H)
    [ "${target_hours#* $now_h}" != "$target_hours" ] || return 0
    date -u +%Y-%m-%dT%H > "$WINDOW_MARKER" 2>/dev/null || true
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
    echo "[watchdog] active: limit=${limit}B threshold=${threshold}B (${MEM_RESTART_PCT}%) interval=${MEM_CHECK_INTERVAL}s grace=${MEM_STARTUP_GRACE}s scheduled_utc_hours=${target_hours:-off} max_uptime=${MAX_UPTIME}s drain=${DRAIN_TIMEOUT}s"

    sleep "$MEM_STARTUP_GRACE"

    while kill -0 "$pid" 2>/dev/null; do
        local uptime_s
        uptime_s=$(( $(date +%s) - started_at ))

        # Hard age cap. Checked FIRST and deliberately unconditional: this is
        # the one restart nothing can skip, so the memory ceiling is never
        # reached in normal operation.
        if [ "$MAX_UPTIME" -gt 0 ] && [ "$uptime_s" -ge "$MAX_UPTIME" ]; then
            stamp_window_if_target
            echo "[watchdog] ⏳ max uptime reached (${uptime_s}s >= ${MAX_UPTIME}s) — terminating uvicorn pid=$pid"
            ship_axiom "watchdog.max_uptime_restart" "INFO" \
                "\"uptime_s\":$uptime_s,\"max_uptime_s\":$MAX_UPTIME,\"pid\":$pid"
            terminate_child "$pid"
            return
        fi

        # Preferred restart windows, so the blip lands in a calm hour rather
        # than wherever the age cap happens to fall. The marker file makes a
        # window fire once per calendar hour ACROSS children — the min-uptime
        # check alone used to be the loop guard, and that is what let an
        # unrelated memory kill swallow the whole window.
        if [ -n "$target_hours" ]; then
            local now_h now_window last_window
            now_h=$(date -u +%H)
            now_window=$(date -u +%Y-%m-%dT%H)
            last_window=$(cat "$WINDOW_MARKER" 2>/dev/null || echo "")
            if [ "${target_hours#* $now_h}" != "$target_hours" ] &&
               [ "$uptime_s" -ge "$DAILY_RESTART_MIN_UPTIME" ] &&
               [ "$last_window" != "$now_window" ]; then
                echo "$now_window" > "$WINDOW_MARKER" 2>/dev/null || true
                echo "[watchdog] ⏰ scheduled restart window (${now_h}:00 UTC, uptime ${uptime_s}s) — terminating uvicorn pid=$pid"
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
            stamp_window_if_target
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
