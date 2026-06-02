#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Pre-Flight Setup Check
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Verifies that all required binaries, models, scripts, and
#           dependencies are in place before first boot. Run this once
#           after assembling the drive and before running startup.sh.
# Usage:    ./setup_check.sh [--root PATH] [--fix-perms]
# Exit:     0 = all critical checks pass (warnings are OK)
#           1 = one or more critical checks failed
# =============================================================================

set -euo pipefail

AERIA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_PERMS=false

# ---------------------------------------------------------------------------
# Colour output — degrades gracefully when stdout is not a terminal
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m';  C_BOLD='\033[1m';   C_DIM='\033[2m'; C_NC='\033[0m'
else
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''; C_NC=''
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0; WARN=0; FAIL=0

# ---------------------------------------------------------------------------
# Check printing helpers
# ---------------------------------------------------------------------------
pass() { echo -e "  ${C_GREEN}[PASS]${C_NC} $*"; PASS=$((PASS+1)); }
warn() { echo -e "  ${C_YELLOW}[WARN]${C_NC} $*"; WARN=$((WARN+1)); }
fail() { echo -e "  ${C_RED}[FAIL]${C_NC} $*"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${C_BLUE}[INFO]${C_NC} $*"; }
hdr()  { echo -e "\n${C_BOLD}$*${C_NC}"; }

hr()   { echo -e "${C_DIM}  ──────────────────────────────────────────────────${C_NC}"; }

human_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576   )); then printf "%.0f MB"  "$(echo "scale=0; $bytes/1048576"   | bc)"
    elif (( bytes >= 1024      )); then printf "%.0f KB"  "$(echo "scale=0; $bytes/1024"      | bc)"
    else printf "%d B" "$bytes"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)      AERIA_ROOT="$2"; shift 2 ;;
        --fix-perms) FIX_PERMS=true;  shift   ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--root PATH] [--fix-perms]"
            echo "  --root PATH      Set AERIA_ROOT (default: parent of this script)"
            echo "  --fix-perms      Auto-chmod +x all Aeria scripts that should be executable"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ===========================================================================
echo -e "\n${C_BOLD}╔══════════════════════════════════════════════════════╗${C_NC}"
echo -e "${C_BOLD}║       Project Aeria — Pre-Flight Setup Check         ║${C_NC}"
echo -e "${C_BOLD}╚══════════════════════════════════════════════════════╝${C_NC}"
echo -e "  AERIA_ROOT: ${C_BLUE}$AERIA_ROOT${C_NC}"
echo -e "  Run time:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ===========================================================================
hdr "1. Directory Structure"
hr
REQUIRED_DIRS=(
    "00_BOOT_SYSTEM" "01_THE_BRAINS" "02_THE_COUNCIL"
    "03_THE_ARCHIVES" "04_THE_SCOUT" "05_USER_ADDITIONS" "06_PERSONAL_VAULT"
)
for d in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$AERIA_ROOT/$d" ]]; then
        pass "$d/"
    else
        fail "$d/ — MISSING. Create it: mkdir -p $AERIA_ROOT/$d"
    fi
done

# ===========================================================================
hdr "2. System Dependencies"
hr

# Python version
if command -v python3 &>/dev/null; then
    PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    PY_MAJ="${PY_VER%%.*}"
    PY_MIN="${PY_VER##*.}"
    if (( PY_MAJ > 3 )) || (( PY_MAJ == 3 && PY_MIN >= 10 )); then
        pass "Python $PY_VER"
    else
        fail "Python $PY_VER found — 3.10+ required. Upgrade Python."
    fi
else
    fail "Python 3 not found — install python3 (3.10+)"
fi

# curl — needed by council_invoke.sh
if command -v curl &>/dev/null; then
    pass "curl $(curl --version | head -1 | awk '{print $2}')"
else
    fail "curl not found — required by council_invoke.sh. Install: sudo apt install curl"
fi

# GPG — needed by vault.sh
if command -v gpg2 &>/dev/null || command -v gpg &>/dev/null; then
    GPG_BIN="$(command -v gpg2 || command -v gpg)"
    GPG_VER="$("$GPG_BIN" --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    pass "GPG $GPG_VER ($GPG_BIN)"
else
    warn "GPG not found — vault.sh will not work. Install: sudo apt install gnupg"
fi

# PDF library — needed by convert_to_text.py and index_archives.py
PDF_LIB=""
if python3 -c "import pdfplumber" &>/dev/null; then
    PDF_LIB="pdfplumber"
elif python3 -c "import pypdf" &>/dev/null; then
    PDF_LIB="pypdf"
elif python3 -c "import PyPDF2" &>/dev/null; then
    PDF_LIB="PyPDF2 (legacy — consider upgrading: pip install pypdf)"
fi

if [[ -n "$PDF_LIB" ]]; then
    pass "PDF library: $PDF_LIB"
else
    warn "No PDF library — cannot convert or index PDFs."
    warn "       Fix: pip install pdfplumber"
fi

# Pillow — optional, used by scout.py for image resizing
if python3 -c "from PIL import Image" &>/dev/null; then
    PIL_VER="$(python3 -c "from PIL import __version__; print(__version__)")"
    pass "Pillow $PIL_VER (image auto-resize enabled)"
else
    info "Pillow not installed — large images sent to Scout without resize."
    info "       Optional: pip install Pillow"
fi

# ===========================================================================
hdr "3. Binaries"
hr

# llamafile (server mode — used by startup.sh)
LLAMAFILE=""
BOOT_DIR="$AERIA_ROOT/00_BOOT_SYSTEM"
if [[ -x "$BOOT_DIR/llamafile" ]]; then
    LLAMAFILE="$BOOT_DIR/llamafile"
else
    LLAMAFILE="$(find "$BOOT_DIR" -maxdepth 1 -name '*.llamafile' -type f -perm /111 \
                 2>/dev/null | sort | head -n 1)"
fi

if [[ -n "$LLAMAFILE" ]]; then
    SZ="$(human_size "$(wc -c < "$LLAMAFILE")")"
    pass "llamafile: $(basename "$LLAMAFILE") ($SZ)"
else
    fail "llamafile binary not found in $BOOT_DIR/"
    fail "       Get it: https://github.com/Mozilla-Ocho/llamafile/releases"
    fail "       Place as: $BOOT_DIR/llamafile  (chmod +x)"
fi

# llama-cli (CLI fallback — used by start-linux-cli.sh and start-windows.bat)
LLAMA_CLI_LINUX="$BOOT_DIR/bin/linux/llama-cli"
LLAMA_CLI_WIN="$BOOT_DIR/bin/win/llama-cli.exe"
LLAMA_CLI_MAC="$BOOT_DIR/bin/mac/llama-cli"

FOUND_CLI=false
for cli_path in "$LLAMA_CLI_LINUX" "$LLAMA_CLI_WIN" "$LLAMA_CLI_MAC"; do
    if [[ -f "$cli_path" ]]; then
        SZ="$(human_size "$(wc -c < "$cli_path")")"
        pass "llama-cli: $(basename "$(dirname "$cli_path")")/$(basename "$cli_path") ($SZ)"
        FOUND_CLI=true
    fi
done
if [[ "$FOUND_CLI" == "false" ]]; then
    warn "llama-cli binary not found — CLI fallback (start-linux-cli.sh) will not work."
    warn "       Get it: https://github.com/ggerganov/llama.cpp/releases"
    warn "       Place as: $BOOT_DIR/bin/linux/llama-cli  (chmod +x)"
fi

# ===========================================================================
hdr "4. Language Models (01_THE_BRAINS/)"
hr

BRAINS_DIR="$AERIA_ROOT/01_THE_BRAINS"
MODELS=()
if [[ -d "$BRAINS_DIR" ]]; then
    while IFS= read -r -d '' f; do
        MODELS+=("$f")
    done < <(find "$BRAINS_DIR" -maxdepth 2 -name '*.gguf' -type f -print0 2>/dev/null | sort -z)
fi

if [[ ${#MODELS[@]} -gt 0 ]]; then
    for m in "${MODELS[@]}"; do
        SZ="$(human_size "$(wc -c < "$m")")"
        pass "$(basename "$m") ($SZ)"
    done
else
    fail "No .gguf models found in $BRAINS_DIR/"
    fail "       Recommended: Qwen2.5-7B-Instruct-Q4_K_M.gguf (~4.7 GB)"
    fail "       Fallback:    gemma-2-2b-it-Q4_K_M.gguf (~1.5 GB)"
    fail "       Source: https://huggingface.co (search model name + GGUF)"
fi

# ===========================================================================
hdr "5. Vision Models (04_THE_SCOUT/)"
hr

SCOUT_DIR="$AERIA_ROOT/04_THE_SCOUT"
VISION_MODEL=""; VISION_MMPROJ=""

if [[ -d "$SCOUT_DIR" ]]; then
    for pat in '*llava*.gguf' '*moondream*.gguf' '*minicpm*.gguf' '*vision*.gguf' '*bakllava*.gguf'; do
        VISION_MODEL="$(find "$SCOUT_DIR" -maxdepth 2 -name "$pat" ! -name 'mmproj*' \
                        -type f 2>/dev/null | sort | head -n 1)"
        [[ -n "$VISION_MODEL" ]] && break
    done
    VISION_MMPROJ="$(find "$SCOUT_DIR" -maxdepth 2 -name 'mmproj*.gguf' \
                    -type f 2>/dev/null | sort | head -n 1)"
fi

if [[ -n "$VISION_MODEL" ]]; then
    SZ="$(human_size "$(wc -c < "$VISION_MODEL")")"
    pass "Vision model: $(basename "$VISION_MODEL") ($SZ)"
else
    warn "No vision model in $SCOUT_DIR/ — Scout will not work."
    warn "       Recommended: moondream2-Q4_K_M.gguf + its mmproj file (~1.7 GB total)"
fi

if [[ -n "$VISION_MMPROJ" ]]; then
    SZ="$(human_size "$(wc -c < "$VISION_MMPROJ")")"
    pass "Vision projector: $(basename "$VISION_MMPROJ") ($SZ)"
elif [[ -n "$VISION_MODEL" ]]; then
    fail "mmproj*.gguf projector not found — vision model will not load without it."
    fail "       Download the mmproj file that matches your vision model."
fi

# ===========================================================================
hdr "6. Council Persona Files (02_THE_COUNCIL/)"
hr

COUNCIL_DIR="$AERIA_ROOT/02_THE_COUNCIL"
for persona in surgeon.prompt.txt blacksmith.prompt.txt engineer.prompt.txt technical_sys.txt; do
    if [[ -f "$COUNCIL_DIR/$persona" ]]; then
        pass "$persona"
    else
        fail "$persona — MISSING. Re-clone the repository."
    fi
done

RAG_SCRIPT="$COUNCIL_DIR/rag_query.py"
if [[ -f "$RAG_SCRIPT" ]]; then
    pass "rag_query.py"
else
    fail "rag_query.py — MISSING. Re-clone the repository."
fi

# ===========================================================================
hdr "7. Script Permissions"
hr

SCRIPTS=(
    "00_BOOT_SYSTEM/startup.sh"
    "00_BOOT_SYSTEM/healthcheck.sh"
    "00_BOOT_SYSTEM/start-linux-cli.sh"
    "02_THE_COUNCIL/council_invoke.sh"
    "04_THE_SCOUT/start_scout.sh"
    "06_PERSONAL_VAULT/vault.sh"
)

NEEDS_FIX=()
for rel in "${SCRIPTS[@]}"; do
    full="$AERIA_ROOT/$rel"
    if [[ ! -f "$full" ]]; then
        warn "$rel — file not found"
    elif [[ -x "$full" ]]; then
        pass "$rel"
    else
        NEEDS_FIX+=("$full")
        if [[ "$FIX_PERMS" == "true" ]]; then
            chmod +x "$full"
            pass "$rel (fixed)"
        else
            warn "$rel — not executable. Run with --fix-perms to auto-fix."
        fi
    fi
done

# ===========================================================================
hdr "8. Archive Status (03_THE_ARCHIVES/)"
hr

ARCHIVES_DIR="$AERIA_ROOT/03_THE_ARCHIVES"
INDEX_DB="$ARCHIVES_DIR/archive_index.db"

# Count source documents
PDF_COUNT=0; TXT_COUNT=0; MD_COUNT=0
if [[ -d "$ARCHIVES_DIR" ]]; then
    PDF_COUNT="$(find "$ARCHIVES_DIR" -name '*.pdf' -type f 2>/dev/null | wc -l)"
    TXT_COUNT="$(find "$ARCHIVES_DIR" -name '*.txt' -type f \
                 ! -name 'archive_index*' 2>/dev/null | wc -l)"
    MD_COUNT="$(find "$ARCHIVES_DIR"  -name '*.md'  -type f 2>/dev/null | wc -l)"
fi
TOTAL_DOCS=$((PDF_COUNT + TXT_COUNT + MD_COUNT))

if [[ $TOTAL_DOCS -eq 0 ]]; then
    warn "No documents in $ARCHIVES_DIR/ — Council agents have no knowledge base."
    warn "       Add PDFs/text files then run: python3 03_THE_ARCHIVES/convert_to_text.py"
else
    info "Documents: $PDF_COUNT PDF, $TXT_COUNT TXT, $MD_COUNT MD ($TOTAL_DOCS total)"
fi

if [[ -f "$INDEX_DB" ]]; then
    CHUNK_COUNT="$(python3 -c "
import sqlite3
try:
    c = sqlite3.connect('file:$INDEX_DB?mode=ro', uri=True)
    print(c.execute('SELECT COUNT(*) FROM chunks').fetchone()[0])
    c.close()
except Exception:
    print(0)
" 2>/dev/null)"
    if [[ "$CHUNK_COUNT" -gt 0 ]]; then
        pass "Archive index: $CHUNK_COUNT chunks indexed"
    else
        warn "Archive index DB exists but is empty."
        warn "       Run: python3 03_THE_ARCHIVES/index_archives.py --root $AERIA_ROOT"
    fi
else
    if [[ $TOTAL_DOCS -gt 0 ]]; then
        warn "Archive index not built yet."
        warn "       Run: python3 03_THE_ARCHIVES/index_archives.py --root $AERIA_ROOT"
    else
        info "Archive index not built (no documents to index yet)"
    fi
fi

# ===========================================================================
hdr "9. Vault Status (06_PERSONAL_VAULT/)"
hr

VAULT_DIR="$AERIA_ROOT/06_PERSONAL_VAULT"
VAULT_GPG_COUNT=0
if [[ -d "$VAULT_DIR" ]]; then
    VAULT_GPG_COUNT="$(find "$VAULT_DIR" -name '*.gpg' -type f 2>/dev/null | wc -l)"
fi

if [[ $VAULT_GPG_COUNT -gt 0 ]]; then
    pass "Vault contains $VAULT_GPG_COUNT encrypted file(s)"
else
    info "Vault is empty — initialise with: ./06_PERSONAL_VAULT/vault.sh init"
fi

if [[ -f "$VAULT_DIR/vault.sh" ]]; then
    pass "vault.sh present"
else
    fail "vault.sh not found in $VAULT_DIR/ — re-clone the repository."
fi

# ===========================================================================
hdr "Summary"
hr

TOTAL=$((PASS + WARN + FAIL))
echo -e "  ${C_GREEN}Passed${C_NC}   : $PASS / $TOTAL checks"
[[ $WARN -gt 0 ]] && echo -e "  ${C_YELLOW}Warnings${C_NC} : $WARN (system will work with degraded capability)"
[[ $FAIL -gt 0 ]] && echo -e "  ${C_RED}Failed${C_NC}   : $FAIL (must fix before first boot)"

echo ""
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "  ${C_GREEN}${C_BOLD}All checks passed. System is ready.${C_NC}"
    echo -e "  Start with: ${C_BLUE}./00_BOOT_SYSTEM/startup.sh --root $AERIA_ROOT${C_NC}"
elif [[ $FAIL -eq 0 ]]; then
    echo -e "  ${C_YELLOW}${C_BOLD}Critical checks passed — warnings noted above.${C_NC}"
    echo -e "  Start with: ${C_BLUE}./00_BOOT_SYSTEM/startup.sh --root $AERIA_ROOT${C_NC}"
else
    echo -e "  ${C_RED}${C_BOLD}Fix the $FAIL failed check(s) above before booting.${C_NC}"
fi

if [[ ${#NEEDS_FIX[@]} -gt 0 && "$FIX_PERMS" == "false" ]]; then
    echo ""
    echo -e "  ${C_DIM}To auto-fix script permissions: $(basename "$0") --fix-perms${C_NC}"
fi

echo ""

[[ $FAIL -gt 0 ]] && exit 1
exit 0
