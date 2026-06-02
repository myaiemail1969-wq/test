#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Boot Script
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Validates the canonical directory structure, launches the llamafile
#           inference engine from 00_BOOT_SYSTEM/, and logs the session start
#           to 05_USER_ADDITIONS/logs/.
# Usage:    ./startup.sh [--root PATH] [--host HOST] [--port PORT] [--model FILE]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — overridden by CLI flags
# ---------------------------------------------------------------------------
AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMAFILE_HOST="127.0.0.1"
LLAMAFILE_PORT=8080
MODEL_OVERRIDE=""
LOG_DIR=""
LOG_FILE=""

REQUIRED_DIRS=(
    "00_BOOT_SYSTEM"
    "01_THE_BRAINS"
    "02_THE_COUNCIL"
    "03_THE_ARCHIVES"
    "04_THE_SCOUT"
    "05_USER_ADDITIONS"
    "06_PERSONAL_VAULT"
)

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root  PATH   Set AERIA_ROOT (default: parent directory of this script)
  --host  HOST   llamafile bind host (default: 127.0.0.1)
  --port  PORT   llamafile bind port (default: 8080)
  --model FILE   GGUF filename inside 01_THE_BRAINS/ to use (auto-detected if omitted)
  -h, --help     Print this message and exit
EOF
}

# ---------------------------------------------------------------------------
# Logging — writes to stdout and to LOG_FILE once it is initialised
# ---------------------------------------------------------------------------
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
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)   AERIA_ROOT="$2";       shift 2 ;;
            --host)   LLAMAFILE_HOST="$2";   shift 2 ;;
            --port)   LLAMAFILE_PORT="$2";   shift 2 ;;
            --model)  MODEL_OVERRIDE="$2";   shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Logging initialisation — must be called after AERIA_ROOT is finalised
# ---------------------------------------------------------------------------
init_logging() {
    LOG_DIR="$AERIA_ROOT/05_USER_ADDITIONS/logs"
    if ! mkdir -p "$LOG_DIR"; then
        echo "[ERROR] Cannot create log directory: $LOG_DIR" >&2
        exit 1
    fi
    LOG_FILE="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S').log"
}

# ---------------------------------------------------------------------------
# Validate canonical directory structure
# ---------------------------------------------------------------------------
validate_structure() {
    log_info "Validating Aeria directory structure under: $AERIA_ROOT"
    local errors=0
    for dir in "${REQUIRED_DIRS[@]}"; do
        if [[ -d "$AERIA_ROOT/$dir" ]]; then
            log_info "  [OK]      $dir"
        else
            log_error "  [MISSING] $dir"
            errors=$((errors + 1))
        fi
    done
    if [[ $errors -gt 0 ]]; then
        log_error "$errors required director(ies) missing. Aborting boot."
        exit 1
    fi
    log_info "Directory structure OK."
}

# ---------------------------------------------------------------------------
# Locate the llamafile binary in 00_BOOT_SYSTEM/
# Precedence: file named exactly 'llamafile' > first *.llamafile executable
# ---------------------------------------------------------------------------
find_llamafile() {
    local boot_dir="$AERIA_ROOT/00_BOOT_SYSTEM"
    if [[ -x "$boot_dir/llamafile" ]]; then
        echo "$boot_dir/llamafile"
        return
    fi
    local found
    found="$(find "$boot_dir" -maxdepth 1 -name '*.llamafile' -type f -perm /111 | sort | head -n 1)"
    echo "$found"
}

# ---------------------------------------------------------------------------
# Locate a GGUF model in 01_THE_BRAINS/
# Auto-selection priority: Q5_K_M > Q4_K_M > any .gguf
# ---------------------------------------------------------------------------
find_model() {
    local brains_dir="$AERIA_ROOT/01_THE_BRAINS"

    if [[ -n "$MODEL_OVERRIDE" ]]; then
        local full="$brains_dir/$MODEL_OVERRIDE"
        if [[ ! -f "$full" ]]; then
            log_error "Specified model not found: $full"
            exit 1
        fi
        echo "$full"
        return
    fi

    local found=""
    for pattern in '*Q5_K_M*.gguf' '*Q4_K_M*.gguf' '*.gguf'; do
        found="$(find "$brains_dir" -maxdepth 2 -name "$pattern" -type f | sort | head -n 1)"
        [[ -n "$found" ]] && break
    done
    echo "$found"
}

# ---------------------------------------------------------------------------
# Launch llamafile as a background daemon; write PID and pipe output to log
# ---------------------------------------------------------------------------
launch_llamafile() {
    local bin="$1"
    local model="$2"
    local pid_file="$LOG_DIR/llamafile.pid"
    local lf_log="$LOG_DIR/llamafile_$(date -u '+%Y%m%d_%H%M%S').log"

    log_info "Launching llamafile..."
    log_info "  Binary  : $bin"
    log_info "  Model   : $model"
    log_info "  Endpoint: http://$LLAMAFILE_HOST:$LLAMAFILE_PORT"
    log_info "  Engine log: $lf_log"

    # VERIFY: confirm --log-disable is the correct flag for your llamafile build
    "$bin" \
        --model   "$model" \
        --host    "$LLAMAFILE_HOST" \
        --port    "$LLAMAFILE_PORT" \
        --log-disable \
        >> "$lf_log" 2>&1 &

    local pid=$!
    echo "$pid" > "$pid_file"
    log_info "llamafile started (PID $pid) — PID saved to $(basename "$pid_file")"

    # Allow up to 5 seconds for the process to stabilise or die cleanly
    local retries=5
    while [[ $retries -gt 0 ]]; do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            log_error "llamafile exited unexpectedly. Check: $lf_log"
            exit 1
        fi
        retries=$((retries - 1))
    done

    log_info "llamafile is running."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_logging

    log_info "========================================================"
    log_info "Project Aeria — Session Start"
    log_info "AERIA_ROOT : $AERIA_ROOT"
    log_info "Log file   : $LOG_FILE"
    log_info "========================================================"

    validate_structure

    local llamafile_bin
    llamafile_bin="$(find_llamafile)"
    if [[ -z "$llamafile_bin" ]]; then
        log_error "No llamafile binary found in $AERIA_ROOT/00_BOOT_SYSTEM/."
        log_error "Place an executable named 'llamafile' or '*.llamafile' there and retry."
        exit 1
    fi

    local model
    model="$(find_model)"
    if [[ -z "$model" ]]; then
        log_error "No .gguf model found in $AERIA_ROOT/01_THE_BRAINS/."
        log_error "Add a quantized model (Q4_K_M or Q5_K_M recommended) and retry."
        exit 1
    fi

    launch_llamafile "$llamafile_bin" "$model"

    log_info "========================================================"
    log_info "Boot sequence complete."
    log_info "========================================================"
}

main "$@"
