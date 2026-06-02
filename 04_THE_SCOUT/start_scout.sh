#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Scout Vision Model Launcher
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Launches a vision-capable llamafile instance on a dedicated port
#           (default 8081) separate from the main Council endpoint (8080).
#           Requires a LLaVA-style model: a GGUF weights file AND a
#           multimodal projector file (mmproj-*.gguf) in 04_THE_SCOUT/.
# Usage:    ./start_scout.sh [--root PATH] [--port PORT]
# =============================================================================

set -euo pipefail

AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOUT_DIR="$AERIA_ROOT/04_THE_SCOUT"
HOST="127.0.0.1"
PORT=8081           # Separate port from main Council llamafile (8080)
LOG_DIR=""
LOG_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root  PATH   Set AERIA_ROOT (default: parent of this script)
  --host  HOST   Bind host (default: 127.0.0.1)
  --port  PORT   Bind port (default: 8081)
  -h, --help     Print this message and exit

Vision models go in 04_THE_SCOUT/:
  Model weights : *llava*.gguf | *vision*.gguf | *moondream*.gguf | *minicpm*.gguf
  Projector     : mmproj*.gguf  (required — the vision encoder)

Recommended models (GGUF Q4_K_M):
  moondream2          ~1.7 GB  fastest, good for general image description
  LLaVA-1.5-7B        ~4.1 GB  stronger reasoning, needs >8 GB RAM
  MiniCPM-V-2         ~4.3 GB  strong on documents and diagrams
EOF
}

_log() {
    local level="$1"; shift
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local line="[$ts] [$level] $*"
    echo "$line"
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE"
}
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)   AERIA_ROOT="$2"; shift 2 ;;
            --host)   HOST="$2";       shift 2 ;;
            --port)   PORT="$2";       shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
        esac
    done
}

init_logging() {
    local ts; ts="$(date -u '+%Y%m%d_%H%M%S')"
    LOG_DIR="$AERIA_ROOT/05_USER_ADDITIONS/logs"
    if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_DIR/.w" 2>/dev/null; then
        LOG_DIR="/tmp/aeria_logs_$ts"
        mkdir -p "$LOG_DIR"
        echo "[WARN ] Read-only media — logs redirected to $LOG_DIR" >&2
    fi
    rm -f "$LOG_DIR/.w"
    LOG_FILE="$LOG_DIR/scout_$ts.log"
}

# ---------------------------------------------------------------------------
# Locate llamafile binary (reuse from 00_BOOT_SYSTEM/)
# ---------------------------------------------------------------------------
find_llamafile() {
    local boot_dir="$AERIA_ROOT/00_BOOT_SYSTEM"
    if [[ -x "$boot_dir/llamafile" ]]; then echo "$boot_dir/llamafile"; return; fi
    local found
    found="$(find "$boot_dir" -maxdepth 1 -name '*.llamafile' -type f -perm /111 \
             | sort | head -n 1)"
    echo "$found"
}

# ---------------------------------------------------------------------------
# Locate vision model in 04_THE_SCOUT/
# LLaVA-style models need two files: main weights + mmproj (vision encoder)
# ---------------------------------------------------------------------------
find_vision_model() {
    local found=""
    for pattern in '*llava*.gguf' '*moondream*.gguf' '*minicpm*.gguf' \
                   '*vision*.gguf' '*bakllava*.gguf'; do
        found="$(find "$SCOUT_DIR" -maxdepth 2 -name "$pattern" -type f \
                 ! -name 'mmproj*' | sort | head -n 1)"
        [[ -n "$found" ]] && break
    done
    echo "$found"
}

find_mmproj() {
    local found
    found="$(find "$SCOUT_DIR" -maxdepth 2 -name 'mmproj*.gguf' -type f \
             | sort | head -n 1)"
    echo "$found"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_logging

    log_info "========================================================"
    log_info "Project Aeria — Scout Vision Node"
    log_info "AERIA_ROOT : $AERIA_ROOT"
    log_info "========================================================"

    local llamafile_bin
    llamafile_bin="$(find_llamafile)"
    if [[ -z "$llamafile_bin" ]]; then
        log_error "No llamafile binary found in $AERIA_ROOT/00_BOOT_SYSTEM/."
        exit 1
    fi

    local model
    model="$(find_vision_model)"
    if [[ -z "$model" ]]; then
        log_error "No vision model found in $SCOUT_DIR/."
        log_error "Add a LLaVA/Moondream/MiniCPM GGUF model and its mmproj file."
        exit 1
    fi

    local mmproj
    mmproj="$(find_mmproj)"
    if [[ -z "$mmproj" ]]; then
        log_error "No multimodal projector (mmproj*.gguf) found in $SCOUT_DIR/."
        log_error "Vision models require both the main weights AND the mmproj file."
        exit 1
    fi

    local pid_file="$LOG_DIR/scout.pid"
    local scout_log="$LOG_DIR/scout_engine_$(date -u '+%Y%m%d_%H%M%S').log"

    log_info "Model    : $(basename "$model")"
    log_info "Projector: $(basename "$mmproj")"
    log_info "Endpoint : http://$HOST:$PORT"

    "$llamafile_bin" \
        --model   "$model" \
        --mmproj  "$mmproj" \
        --host    "$HOST" \
        --port    "$PORT" \
        >> "$scout_log" 2>&1 &

    local pid=$!
    echo "$pid" > "$pid_file"
    log_info "Scout started (PID $pid)"

    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "Scout exited immediately. Check: $scout_log"
        exit 1
    fi

    local healthcheck="$AERIA_ROOT/00_BOOT_SYSTEM/healthcheck.sh"
    if [[ -x "$healthcheck" ]]; then
        "$healthcheck" --host "$HOST" --port "$PORT" --timeout 60 --log "$LOG_FILE"
    fi

    log_info "Scout is ready. Endpoint: http://$HOST:$PORT"
    log_info "Use: python3 $SCOUT_DIR/scout.py IMAGE [--mode wound|plant|map|...]"
}

main "$@"
