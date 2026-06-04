#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Linux CLI Fallback Boot Script
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Launches llama-cli directly for interactive terminal use.
#           No server, no daemon, no dependencies beyond the binary.
#           Safe on read-only media — all writes go to /tmp.
#           Use this script on salvaged or resource-constrained hardware
#           where the full server stack (startup.sh) is impractical.
# Usage:    ./start-linux-cli.sh [--root PATH] [--model FILE] [--gpu-layers N]
# =============================================================================

set -euo pipefail

AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_OVERRIDE=""
GPU_LAYERS=99        # Try to offload all layers to GPU; set 0 to force CPU
CONTEXT_SIZE=4096
LOG_DIR="/tmp/aeria_logs"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root       PATH  Set AERIA_ROOT (default: parent of this script)
  --model      FILE  GGUF filename in 01_THE_BRAINS/ (auto-detected if omitted)
  --gpu-layers N     Layers to offload to GPU (default: 99 = all; 0 = CPU only)
  --context    N     Context size in tokens (default: 4096)
  -h, --help         Print this message and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)       AERIA_ROOT="$2";     shift 2 ;;
            --model)      MODEL_OVERRIDE="$2"; shift 2 ;;
            --gpu-layers) GPU_LAYERS="$2";     shift 2 ;;
            --context)    CONTEXT_SIZE="$2";   shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Locate llama-cli binary
# ---------------------------------------------------------------------------
find_llama_cli() {
    local bin_dir="$AERIA_ROOT/00_BOOT_SYSTEM/bin/linux"
    if [[ -x "$bin_dir/llama-cli" ]]; then
        echo "$bin_dir/llama-cli"
        return
    fi
    # Also accept it alongside this script (flat deployment)
    local here
    here="$(dirname "${BASH_SOURCE[0]}")"
    if [[ -x "$here/llama-cli" ]]; then
        echo "$here/llama-cli"
        return
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Locate a GGUF model — same priority order as startup.sh
# ---------------------------------------------------------------------------
find_model() {
    local brains_dir="$AERIA_ROOT/01_THE_BRAINS"
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        local full="$brains_dir/$MODEL_OVERRIDE"
        [[ ! -f "$full" ]] && { echo "[ERROR] Model not found: $full" >&2; exit 1; }
        echo "$full"; return
    fi
    local found=""
    for pattern in '*Q5_K_M*.gguf' '*Q4_K_M*.gguf' '*.gguf'; do
        found="$(find "$brains_dir" -maxdepth 2 -name "$pattern" -type f | sort | head -n 1)"
        [[ -n "$found" ]] && break
    done
    echo "$found"
}

# ---------------------------------------------------------------------------
# Interactive model selection (with timeout fallback to smallest available)
# ---------------------------------------------------------------------------
select_model() {
    local brains_dir="$AERIA_ROOT/01_THE_BRAINS"
    local models
    mapfile -t models < <(find "$brains_dir" -maxdepth 2 -name '*.gguf' -type f | sort)

    if [[ ${#models[@]} -eq 0 ]]; then
        echo "[ERROR] No .gguf models found in $brains_dir" >&2
        echo "  Add a quantized model (Q4_K_M or Q5_K_M) and retry." >&2
        exit 1
    fi

    if [[ ${#models[@]} -eq 1 ]]; then
        echo "${models[0]}"
        return
    fi

    echo ""
    echo "  Available models:"
    for i in "${!models[@]}"; do
        printf "  [%d] %s\n" $((i+1)) "$(basename "${models[$i]}")"
    done
    echo ""

    local choice=""
    # 15-second timeout — defaults to first model (smallest)
    if read -r -t 15 -p "  Select model [1-${#models[@]}] (default: 1): " choice; then
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
            echo "${models[$((choice-1))]}"
            return
        fi
    fi
    # Timeout or invalid input — use first (smallest) model
    echo "${models[0]}"
}

main() {
    parse_args "$@"

    echo ""
    echo "==================================================="
    echo "  Project Aeria — Offline CLI Node (Linux)"
    echo "==================================================="
    echo ""

    local llama_bin
    llama_bin="$(find_llama_cli)"
    if [[ -z "$llama_bin" ]]; then
        echo "[ERROR] llama-cli binary not found." >&2
        echo "  Expected: $AERIA_ROOT/00_BOOT_SYSTEM/bin/linux/llama-cli" >&2
        echo "  Download from: https://github.com/ggerganov/llama.cpp/releases" >&2
        exit 1
    fi

    local model
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        model="$(find_model)"
    else
        model="$(select_model)"
    fi

    local prompt_file="$AERIA_ROOT/02_THE_COUNCIL/technical_sys.txt"
    local prompt_flag=()
    if [[ -f "$prompt_file" ]]; then
        prompt_flag=(-f "$prompt_file")
    else
        echo "[WARN ] System prompt not found at $prompt_file — running without primer."
    fi

    mkdir -p "$LOG_DIR"
    local session_log="$LOG_DIR/cli_session_$(date -u '+%Y%m%d_%H%M%S').log"

    echo "  Binary     : $llama_bin"
    echo "  Model      : $(basename "$model")"
    echo "  GPU layers : $GPU_LAYERS"
    echo "  Context    : $CONTEXT_SIZE tokens"
    echo "  Log        : $session_log"
    echo ""
    echo "  Type your question. Type /bye or Ctrl+C to exit."
    echo "==================================================="
    echo ""

    "$llama_bin" \
        -m "$model" \
        -c "$CONTEXT_SIZE" \
        --color \
        "${prompt_flag[@]}" \
        -ngl "$GPU_LAYERS" \
        --conversation \
        2>&1 | tee "$session_log"
}

main "$@"
