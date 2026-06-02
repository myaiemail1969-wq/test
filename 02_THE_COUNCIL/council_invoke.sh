#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Council Invocation Script
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Loads a Council persona system prompt and sends a query to the
#           local llamafile endpoint via the OpenAI-compatible chat API.
#           All inference is local — no network calls leave this machine.
# Usage:    ./council_invoke.sh --agent surgeon|blacksmith|engineer --query "TEXT"
#           ./council_invoke.sh --agent surgeon --query "Patient has arterial bleed..."
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
LOG_DIR="$AERIA_ROOT/05_USER_ADDITIONS/logs"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --root      PATH    Set AERIA_ROOT (default: parent of this script)
  --host      HOST    llamafile host (default: 127.0.0.1)
  --port      PORT    llamafile port (default: 8080)
  --agent     NAME    Council member: surgeon | blacksmith | engineer
  --query     TEXT    Question or situation to present to the agent
  --max-tokens N      Max response tokens (default: 2048)
  -h, --help          Print this message and exit

Examples:
  ./council_invoke.sh --agent surgeon   --query "Femoral artery bleed, no tourniquet available"
  ./council_invoke.sh --agent blacksmith --query "Harden a leaf spring for a draw knife"
  ./council_invoke.sh --agent engineer  --query "Size a gravity-fed cistern for 4 people"
EOF
}

_log() {
    local level="$1"; shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[$ts] [$level] $*" >&2
}
log_info()  { _log "INFO " "$@"; }
log_error() { _log "ERROR" "$@"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)       AERIA_ROOT="$2";    shift 2 ;;
            --host)       HOST="$2";          shift 2 ;;
            --port)       PORT="$2";          shift 2 ;;
            --agent)      AGENT="$2";         shift 2 ;;
            --query)      QUERY="$2";         shift 2 ;;
            --max-tokens) MAX_TOKENS="$2";    shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            *) log_error "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Resolve agent name to prompt file
# ---------------------------------------------------------------------------
resolve_prompt_file() {
    local agent="$1"
    local prompt_file=""

    case "${agent,,}" in   # lowercase match
        surgeon)    prompt_file="$COUNCIL_DIR/surgeon.prompt.txt" ;;
        blacksmith) prompt_file="$COUNCIL_DIR/blacksmith.prompt.txt" ;;
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
# Send query to llamafile via OpenAI-compatible /v1/chat/completions
# ---------------------------------------------------------------------------
invoke_agent() {
    local system_prompt="$1"
    local user_query="$2"
    local endpoint="http://$HOST:$PORT/v1/chat/completions"

    # Build JSON payload — escape the prompt strings for safe embedding
    local payload
    payload="$(python3 -c "
import json, sys
system = sys.argv[1]
query  = sys.argv[2]
max_tokens = int(sys.argv[3])
temp = float(sys.argv[4])
payload = {
    'model': 'local',
    'temperature': temp,
    'max_tokens': max_tokens,
    'messages': [
        {'role': 'system',  'content': system},
        {'role': 'user',    'content': query}
    ]
}
print(json.dumps(payload))
" "$system_prompt" "$user_query" "$MAX_TOKENS" "$TEMPERATURE")"

    local response
    response="$(curl -s -X POST "$endpoint" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        --max-time 120)"

    # Extract the assistant message content
    local content
    content="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if 'error' in data:
    print('[ERROR] llamafile returned: ' + str(data['error']), file=sys.stderr)
    sys.exit(1)
print(data['choices'][0]['message']['content'])
" <<< "$response")"

    echo "$content"
}

# ---------------------------------------------------------------------------
# Log the query and response
# ---------------------------------------------------------------------------
log_session() {
    local agent="$1"
    local query="$2"
    local response="$3"

    mkdir -p "$LOG_DIR"
    local log_file="$LOG_DIR/council_$(date -u '+%Y%m%d_%H%M%S')_${agent}.log"
    {
        echo "AGENT:    @$(tr '[:lower:]' '[:upper:]' <<< "${agent:0:1}")${agent:1}"
        echo "TIME:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "QUERY:"
        echo "$query"
        echo ""
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

    if [[ -z "$AGENT" ]]; then
        log_error "--agent is required."
        usage; exit 1
    fi
    if [[ -z "$QUERY" ]]; then
        log_error "--query is required."
        usage; exit 1
    fi

    local prompt_file
    prompt_file="$(resolve_prompt_file "$AGENT")"
    local system_prompt
    system_prompt="$(cat "$prompt_file")"

    log_info "Consulting @${AGENT^} ..."
    log_info "Endpoint: http://$HOST:$PORT"

    local response
    response="$(invoke_agent "$system_prompt" "$QUERY")"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  @${AGENT^^} RESPONSE"
    echo "════════════════════════════════════════════════════"
    echo "$response"
    echo "════════════════════════════════════════════════════"
    echo ""

    log_session "$AGENT" "$QUERY" "$response"
}

main "$@"
