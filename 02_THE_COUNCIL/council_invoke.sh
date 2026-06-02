#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Council Invocation Script
# Author:   Project Aeria
# Version:  2.0.0
# Modified: YYYY-MM-DD
# Purpose:  Loads a Council persona, retrieves relevant archive context via
#           RAG (rag_query.py → archive_index.db), injects the context into
#           the system prompt, and sends the enriched query to the local
#           llamafile endpoint. All inference is local — no network calls
#           leave this machine.
# Usage:    ./council_invoke.sh --agent surgeon|blacksmith|engineer --query "TEXT"
# =============================================================================

set -euo pipefail

AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNCIL_DIR="$AERIA_ROOT/02_THE_COUNCIL"
HOST="127.0.0.1"
PORT=8080
AGENT=""
QUERY=""
MAX_TOKENS=2048
TEMPERATURE=0.2   # Low temp: factual, austere-condition guidance
USE_RAG=true
RAG_TOP_K=3       # Chunks to inject — keeps total context within 4096-token window
LOG_DIR="$AERIA_ROOT/05_USER_ADDITIONS/logs"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root       PATH   Set AERIA_ROOT (default: parent of this script)
  --host       HOST   llamafile host (default: 127.0.0.1)
  --port       PORT   llamafile port (default: 8080)
  --agent      NAME   Council member: surgeon | blacksmith | engineer
  --query      TEXT   Question or situation to present to the agent
  --max-tokens N      Max response tokens (default: 2048)
  --rag-top-k  N      Archive chunks to inject into context (default: 3)
  --no-rag            Skip archive retrieval (use when index is not built yet)
  -h, --help          Print this message and exit

Examples:
  ./council_invoke.sh --agent surgeon    --query "Femoral artery bleed, no tourniquet"
  ./council_invoke.sh --agent blacksmith --query "Harden a leaf spring for a draw knife"
  ./council_invoke.sh --agent engineer   --query "Size a gravity-fed cistern for 4 people"
  ./council_invoke.sh --agent surgeon    --query "..." --no-rag
EOF
}

_log() {
    local level="$1"; shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[$ts] [$level] $*" >&2
}
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)        AERIA_ROOT="$2";  shift 2 ;;
            --host)        HOST="$2";        shift 2 ;;
            --port)        PORT="$2";        shift 2 ;;
            --agent)       AGENT="$2";       shift 2 ;;
            --query)       QUERY="$2";       shift 2 ;;
            --max-tokens)  MAX_TOKENS="$2";  shift 2 ;;
            --rag-top-k)   RAG_TOP_K="$2";   shift 2 ;;
            --no-rag)      USE_RAG=false;    shift   ;;
            -h|--help)     usage; exit 0 ;;
            *) log_error "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Resolve agent name to persona prompt file
# ---------------------------------------------------------------------------
resolve_prompt_file() {
    local agent="$1"
    local prompt_file=""
    case "${agent,,}" in
        surgeon)          prompt_file="$COUNCIL_DIR/surgeon.prompt.txt" ;;
        blacksmith)       prompt_file="$COUNCIL_DIR/blacksmith.prompt.txt" ;;
        engineer|builder) prompt_file="$COUNCIL_DIR/engineer.prompt.txt" ;;
        *)
            log_error "Unknown agent: '$agent'. Choose: surgeon | blacksmith | engineer"
            exit 1
            ;;
    esac
    if [[ ! -f "$prompt_file" ]]; then
        log_error "Persona file not found: $prompt_file"
        exit 1
    fi
    echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Retrieve relevant archive chunks via rag_query.py.
# Returns the formatted context block on stdout, or empty string if:
#   - rag_query.py is absent
#   - the archive index does not exist yet
#   - no relevant chunks were found
# Failures here are non-fatal: the agent runs without archive context.
# ---------------------------------------------------------------------------
get_rag_context() {
    local query="$1"
    local rag_script="$COUNCIL_DIR/rag_query.py"
    local db="$AERIA_ROOT/03_THE_ARCHIVES/archive_index.db"

    if [[ ! -f "$rag_script" ]]; then
        log_warn "RAG: rag_query.py not found — skipping archive retrieval."
        return
    fi
    if [[ ! -f "$db" ]]; then
        log_warn "RAG: No archive index found — run index_archives.py first."
        return
    fi

    local context
    context="$(python3 "$rag_script" \
        --root    "$AERIA_ROOT" \
        --query   "$query" \
        --top-k   "$RAG_TOP_K" \
        --format  prompt 2>/dev/null)" || true

    echo "$context"
}

# ---------------------------------------------------------------------------
# Send the enriched prompt + query to llamafile
# ---------------------------------------------------------------------------
invoke_agent() {
    local system_prompt="$1"
    local user_query="$2"
    local endpoint="http://$HOST:$PORT/v1/chat/completions"

    local payload
    payload="$(python3 -c "
import json, sys
payload = {
    'model': 'local',
    'temperature': float(sys.argv[4]),
    'max_tokens': int(sys.argv[3]),
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user',   'content': sys.argv[2]},
    ]
}
print(json.dumps(payload))
" "$system_prompt" "$user_query" "$MAX_TOKENS" "$TEMPERATURE")"

    local response
    response="$(curl -s -X POST "$endpoint" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        --max-time 180)"

    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if 'error' in data:
    print('[ERROR] llamafile: ' + str(data['error']), file=sys.stderr)
    sys.exit(1)
print(data['choices'][0]['message']['content'])
" <<< "$response"
}

# ---------------------------------------------------------------------------
# Append a full session record (query, context used, response) to the log
# ---------------------------------------------------------------------------
log_session() {
    local agent="$1"
    local query="$2"
    local context="$3"
    local response="$4"

    # Fall back to /tmp if the drive is read-only
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_DIR="/tmp/aeria_logs"
        mkdir -p "$LOG_DIR"
    fi

    local log_file="$LOG_DIR/council_$(date -u '+%Y%m%d_%H%M%S')_${agent}.log"
    {
        echo "AGENT:    @${agent^}"
        echo "TIME:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "RAG:      $([ -n "$context" ] && echo "yes (${#context} chars)" || echo "no")"
        echo ""
        echo "QUERY:"
        echo "$query"
        echo ""
        if [[ -n "$context" ]]; then
            echo "$context"
            echo ""
        fi
        echo "RESPONSE:"
        echo "$response"
    } > "$log_file"

    log_info "Session saved: $log_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    if [[ -z "$AGENT" ]]; then log_error "--agent is required."; usage; exit 1; fi
    if [[ -z "$QUERY" ]]; then log_error "--query is required.";  usage; exit 1; fi

    local prompt_file
    prompt_file="$(resolve_prompt_file "$AGENT")"
    local persona
    persona="$(cat "$prompt_file")"

    # RAG: retrieve archive context and prepend to the persona system prompt
    local context=""
    if [[ "$USE_RAG" == "true" ]]; then
        log_info "RAG: querying archive index (top-$RAG_TOP_K)..."
        context="$(get_rag_context "$QUERY")"
        if [[ -n "$context" ]]; then
            local chunk_count
            chunk_count="$(grep -c '^─\{56\}' <<< "$context" || true)"
            log_info "RAG: $chunk_count chunk(s) retrieved — injecting into system prompt."
        else
            log_info "RAG: no relevant archive chunks found — proceeding without context."
        fi
    else
        log_info "RAG: disabled by --no-rag flag."
    fi

    # Combine: persona + context block (if any)
    local system_prompt="$persona"
    if [[ -n "$context" ]]; then
        system_prompt="${persona}

${context}"
    fi

    log_info "Consulting @${AGENT^} ..."
    log_info "Endpoint: http://$HOST:$PORT"

    local response
    response="$(invoke_agent "$system_prompt" "$QUERY")"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  @${AGENT^^} RESPONSE"
    if [[ -n "$context" ]]; then
        echo "  (grounded in archive context)"
    fi
    echo "════════════════════════════════════════════════════"
    echo "$response"
    echo "════════════════════════════════════════════════════"
    echo ""

    log_session "$AGENT" "$QUERY" "$context" "$response"
}

main "$@"
