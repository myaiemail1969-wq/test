#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Shutdown Script
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Cleanly stops all running Aeria background processes (llamafile
#           Council server, Scout vision server) by reading PID files written
#           by startup.sh and start_scout.sh. Safe to run multiple times.
# Usage:    ./shutdown.sh [--root PATH] [--force]
# =============================================================================

set -euo pipefail

AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root  PATH   Set AERIA_ROOT (default: parent of this script)
  --force        Send SIGKILL immediately instead of graceful SIGTERM + wait
  -h, --help     Print this message and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)   AERIA_ROOT="$2"; shift 2 ;;
            --force)  FORCE=true;      shift   ;;
            -h|--help) usage; exit 0 ;;
            *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
        esac
    done
}

_ts()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_log()  {
    local level="$1"; shift
    echo "[$(_ts)] [$level] $*"
}
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Stop a process by its PID file
# Returns 0 if stopped (or was already gone), 1 if still running after wait
# ---------------------------------------------------------------------------
stop_process() {
    local name="$1"
    local pid_file="$2"
    local wait_secs="${3:-10}"

    if [[ ! -f "$pid_file" ]]; then
        log_info "$name: no PID file found — not running or already stopped."
        return 0
    fi

    local pid
    pid="$(cat "$pid_file")"

    if ! kill -0 "$pid" 2>/dev/null; then
        log_info "$name: PID $pid no longer exists — cleaning up PID file."
        rm -f "$pid_file"
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        log_info "$name: sending SIGKILL to PID $pid..."
        kill -9 "$pid" 2>/dev/null || true
    else
        log_info "$name: sending SIGTERM to PID $pid (graceful)..."
        kill -TERM "$pid" 2>/dev/null || true

        local elapsed=0
        while kill -0 "$pid" 2>/dev/null && (( elapsed < wait_secs )); do
            sleep 1
            elapsed=$((elapsed + 1))
        done

        if kill -0 "$pid" 2>/dev/null; then
            log_warn "$name: still running after ${wait_secs}s — sending SIGKILL."
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # Final check
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        log_error "$name: PID $pid could not be stopped."
        return 1
    fi

    rm -f "$pid_file"
    log_info "$name: stopped (PID $pid)."
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo "========================================================"
    echo "  Project Aeria — Shutdown"
    echo "  AERIA_ROOT : $AERIA_ROOT"
    echo "========================================================"

    local log_dir="$AERIA_ROOT/05_USER_ADDITIONS/logs"
    # Use /tmp if drive is read-only
    mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp/aeria_logs"

    local errors=0

    # Council llamafile server (started by startup.sh)
    stop_process "llamafile (Council)" "$log_dir/llamafile.pid" 15 || errors=$((errors+1))

    # Scout vision server (started by start_scout.sh)
    stop_process "llamafile (Scout)"   "$log_dir/scout.pid"     15 || errors=$((errors+1))

    # Log the shutdown event
    echo "[$(_ts)] [INFO ] Shutdown complete." >> "$log_dir/session_$(date -u '+%Y%m%d').log" 2>/dev/null || true

    echo ""
    if [[ $errors -eq 0 ]]; then
        echo "  All Aeria processes stopped."
    else
        echo "  $errors process(es) could not be stopped — check logs."
    fi
    echo "========================================================"
    echo ""

    [[ $errors -gt 0 ]] && exit 1
    exit 0
}

main "$@"
