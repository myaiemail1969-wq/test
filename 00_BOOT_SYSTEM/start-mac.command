#!/usr/bin/env bash
# =============================================================================
# Project Aeria — macOS CLI Boot Script
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Double-clickable macOS launcher (.command files open in Terminal).
#           Runs llama-cli directly for interactive offline use — no server,
#           no daemon. Safe on read-only media — writes only to /tmp.
# Usage:    Double-click in Finder, or: bash start-mac.command
# =============================================================================

set -euo pipefail

# .command files run with working directory set to ~, so resolve paths
# relative to this script's actual location
AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_OVERRIDE=""
GPU_LAYERS=1        # Apple Silicon GPU offload via Metal; set 0 for CPU only
CONTEXT_SIZE=4096
LOG_DIR="/tmp/aeria_logs"

# ---------------------------------------------------------------------------
# Ensure Terminal window has a useful title
# ---------------------------------------------------------------------------
echo -ne "\033]0;Project Aeria — Offline Node\007"

echo ""
echo "==================================================="
echo "  Project Aeria — Offline CLI Node (macOS)"
echo "==================================================="
echo ""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--root PATH] [--model FILE] [--gpu-layers N]
  --root       PATH  AERIA_ROOT (default: parent of this script)
  --model      FILE  GGUF filename in 01_THE_BRAINS/ (auto-detected)
  --gpu-layers N     Metal GPU layers (default: 1; 0 = CPU only)
  --context    N     Context window tokens (default: 4096)
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
            *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Locate llama-cli — prefer mac binary, fall back to any llama-cli on PATH
# ---------------------------------------------------------------------------
find_llama_cli() {
    local mac_bin="$AERIA_ROOT/00_BOOT_SYSTEM/bin/mac/llama-cli"
    [[ -x "$mac_bin" ]] && { echo "$mac_bin"; return; }
    # Also check alongside this script
    local here_bin="$(dirname "${BASH_SOURCE[0]}")/llama-cli"
    [[ -x "$here_bin" ]] && { echo "$here_bin"; return; }
    # Last resort: system PATH
    command -v llama-cli 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Auto-select model: Q5_K_M > Q4_K_M > any .gguf
# ---------------------------------------------------------------------------
find_model() {
    local brains="$AERIA_ROOT/01_THE_BRAINS"
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        local full="$brains/$MODEL_OVERRIDE"
        [[ ! -f "$full" ]] && { echo "[ERROR] Model not found: $full" >&2; exit 1; }
        echo "$full"; return
    fi
    local found=""
    for pat in '*Q5_K_M*.gguf' '*Q4_K_M*.gguf' '*.gguf'; do
        found="$(find "$brains" -maxdepth 2 -name "$pat" -type f | sort | head -n 1)"
        [[ -n "$found" ]] && break
    done
    echo "$found"
}

# ---------------------------------------------------------------------------
# Interactive model picker with 15-second timeout
# ---------------------------------------------------------------------------
select_model() {
    local brains="$AERIA_ROOT/01_THE_BRAINS"
    local -a models
    mapfile -t models < <(find "$brains" -maxdepth 2 -name '*.gguf' -type f | sort)

    [[ ${#models[@]} -eq 0 ]] && {
        echo "[ERROR] No .gguf models in $brains/" >&2
        echo "        Add a quantized model and retry." >&2
        exit 1
    }
    [[ ${#models[@]} -eq 1 ]] && { echo "${models[0]}"; return; }

    echo "  Available models:"
    for i in "${!models[@]}"; do
        local sz; sz="$(wc -c < "${models[$i]}")"
        printf "  [%d] %-40s  (%d MB)\n" $((i+1)) "$(basename "${models[$i]}")" $((sz/1048576))
    done
    echo ""
    local choice=""
    if read -r -t 15 -p "  Select [1-${#models[@]}] (default: 1 in 15s): " choice; then
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
            echo "${models[$((choice-1))]}"; return
        fi
    fi
    echo ""
    echo "${models[0]}"
}

main() {
    parse_args "$@"

    local llama_bin
    llama_bin="$(find_llama_cli)"
    if [[ -z "$llama_bin" ]]; then
        echo "[ERROR] llama-cli not found." >&2
        echo "  Expected: $AERIA_ROOT/00_BOOT_SYSTEM/bin/mac/llama-cli" >&2
        echo "  Download: https://github.com/ggerganov/llama.cpp/releases" >&2
        echo "  Look for: llama-...-bin-macos-arm64.zip" >&2
        echo ""; read -r -p "Press Enter to close..." _; exit 1
    fi

    local model
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        model="$(find_model)"
    else
        model="$(select_model)"
    fi

    local prompt_file="$AERIA_ROOT/02_THE_COUNCIL/technical_sys.txt"
    local prompt_flag=()
    [[ -f "$prompt_file" ]] && prompt_flag=(-f "$prompt_file")

    mkdir -p "$LOG_DIR"
    local session_log="$LOG_DIR/mac_session_$(date -u '+%Y%m%d_%H%M%S').log"

    echo ""
    echo "  Model      : $(basename "$model")"
    echo "  GPU layers : $GPU_LAYERS (Metal)"
    echo "  Context    : $CONTEXT_SIZE tokens"
    echo "  Log        : $session_log"
    echo ""
    echo "  Type your question. /bye or Ctrl+C to exit."
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

    echo ""
    echo "  Session ended. Log saved to $session_log"
    echo ""; read -r -p "Press Enter to close..." _
}

main "$@"
