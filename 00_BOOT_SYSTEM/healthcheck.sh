#!/usr/bin/env bash
# =============================================================================
# Project Aeria — llamafile Health Check
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Polls the llamafile HTTP endpoint until it responds or times out.
#           Exits 0 on success, 1 on timeout/failure.
# Usage:    ./healthcheck.sh [--host HOST] [--port PORT] [--timeout SECONDS]
# =============================================================================

set -euo pipefail

HOST="127.0.0.1"
PORT=8080
TIMEOUT=30
INTERVAL=2
LOG_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --host    HOST     llamafile host (default: 127.0.0.1)
  --port    PORT     llamafile port (default: 8080)
  --timeout SECONDS  Max seconds to wait (default: 30)
  --log     FILE     Append output to this log file as well as stdout
  -h, --help         Print this message and exit
EOF
}

_log() {
    local level="$1"; shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local line="[$ts] [$level] $*"
    echo "$line"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}
log_info()  { _log "INFO " "$@"; }
log_error() { _log "ERROR" "$@"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)    HOST="$2";    shift 2 ;;
            --port)    PORT="$2";    shift 2 ;;
            --timeout) TIMEOUT="$2"; shift 2 ;;
            --log)     LOG_FILE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Poll /health until HTTP 200 or timeout
# llamafile (llama.cpp server) exposes GET /health -> {"status":"ok"}
# ---------------------------------------------------------------------------
wait_for_ready() {
    local endpoint="http://$HOST:$PORT/health"
    local elapsed=0

    log_info "Waiting for llamafile at $endpoint (timeout: ${TIMEOUT}s)"

    while [[ $elapsed -lt $TIMEOUT ]]; do
        local http_code
        # curl: silent, follow redirects, output to /dev/null, print status code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time "$INTERVAL" \
            --connect-timeout "$INTERVAL" \
            "$endpoint" 2>/dev/null || true)"

        if [[ "$http_code" == "200" ]]; then
            log_info "llamafile is ready (${elapsed}s elapsed)."
            return 0
        fi

        log_info "  Not ready yet (HTTP ${http_code:-000}) — retrying in ${INTERVAL}s..."
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    log_error "llamafile did not become ready within ${TIMEOUT}s."
    log_error "Check the engine log for errors."
    return 1
}

main() {
    parse_args "$@"
    wait_for_ready
}

main "$@"
