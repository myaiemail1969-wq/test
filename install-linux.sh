#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Linux/macOS Drive Installer
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  One-shot setup script. Clones the repo, creates directory
#           structure, installs Python dependencies, downloads llamafile
#           and llama-cli, and prints what still needs to be done manually.
# Usage:    ./install-linux.sh [TARGET_PATH]
#           ./install-linux.sh /mnt/aeria
# Default:  /mnt/aeria (change DEFAULT_TARGET below if needed)
# =============================================================================

set -euo pipefail

DEFAULT_TARGET="/mnt/aeria"
TARGET="${1:-$DEFAULT_TARGET}"
REPO_URL="https://github.com/myaiemail1969-wq/test"
REPO_BRANCH="claude/aeria-system-prompt-khwmY"
LLAMAFILE_URL="https://github.com/Mozilla-Ocho/llamafile/releases/latest/download/llamafile"

# Detect platform
PLATFORM="linux"
[[ "$(uname -s)" == "Darwin" ]] && PLATFORM="mac"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
    B='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    G=''; R=''; Y=''; B=''; BOLD=''; NC=''
fi

ok()   { echo -e "  ${G}[OK]${NC}   $*"; }
fail() { echo -e "  ${R}[FAIL]${NC} $*"; }
warn() { echo -e "  ${Y}[WARN]${NC} $*"; }
info() { echo -e "  ${B}[INFO]${NC} $*"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=====================================================${NC}"
echo -e "${BOLD}  Project Aeria — Drive Installer (Linux/macOS)${NC}"
echo -e "${BOLD}  Target : $TARGET${NC}"
echo -e "${BOLD}  Platform: $PLATFORM${NC}"
echo -e "${BOLD}=====================================================${NC}\n"

# ---------------------------------------------------------------------------
hdr "[1/7] Checking prerequisites..."
# ---------------------------------------------------------------------------
MISSING=false

if command -v git &>/dev/null; then
    ok "git $(git --version | awk '{print $3}')"
else
    fail "git not found."
    echo "       Linux : sudo apt install git"
    echo "       macOS : xcode-select --install"
    MISSING=true
fi

if command -v python3 &>/dev/null; then
    PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    PY_MIN="${PY_VER##*.}"
    if (( ${PY_VER%%.*} >= 3 && PY_MIN >= 10 )); then
        ok "Python $PY_VER"
    else
        fail "Python $PY_VER found — 3.10+ required"
        MISSING=true
    fi
else
    fail "python3 not found — install Python 3.10+"
    MISSING=true
fi

if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
    ok "pip found"
else
    fail "pip not found — install: python3 -m ensurepip"
    MISSING=true
fi

if command -v curl &>/dev/null; then
    ok "curl $(curl --version | head -1 | awk '{print $2}')"
else
    warn "curl not found — binary download will be skipped"
    warn "  Linux : sudo apt install curl"
fi

if [[ "$MISSING" == "true" ]]; then
    echo ""
    echo "  Prerequisites missing. Install them and re-run."
    exit 1
fi

# ---------------------------------------------------------------------------
hdr "[2/7] Creating directory structure at $TARGET..."
# ---------------------------------------------------------------------------
mkdir -p "$TARGET"

REQUIRED_DIRS=(
    "00_BOOT_SYSTEM/bin/linux"
    "00_BOOT_SYSTEM/bin/win"
    "00_BOOT_SYSTEM/bin/mac"
    "01_THE_BRAINS"
    "02_THE_COUNCIL"
    "03_THE_ARCHIVES"
    "04_THE_SCOUT"
    "05_USER_ADDITIONS/logs"
    "06_PERSONAL_VAULT"
)
for d in "${REQUIRED_DIRS[@]}"; do
    mkdir -p "$TARGET/$d"
    ok "$d/"
done

# ---------------------------------------------------------------------------
hdr "[3/7] Getting Aeria code..."
# ---------------------------------------------------------------------------
if [[ -d "$TARGET/.git" ]]; then
    echo "  Repo exists — pulling latest..."
    git -C "$TARGET" fetch origin "$REPO_BRANCH"
    git -C "$TARGET" checkout "$REPO_BRANCH"
    git -C "$TARGET" pull origin "$REPO_BRANCH"
    ok "Code updated."
elif [[ -f "$TARGET/00_BOOT_SYSTEM/startup.sh" ]]; then
    ok "Code already present (no .git). Skipping clone."
else
    echo "  Cloning from $REPO_URL ..."
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$TARGET"
    ok "Cloned."
fi

# Make all scripts executable
find "$TARGET" -name "*.sh" -type f -exec chmod +x {} \;
ok "Script permissions set."

# ---------------------------------------------------------------------------
hdr "[4/7] Installing Python dependencies..."
# ---------------------------------------------------------------------------
PIP="pip3"
command -v pip3 &>/dev/null || PIP="pip"

if "$PIP" install --quiet pdfplumber 2>/dev/null; then
    ok "pdfplumber installed"
else
    warn "pdfplumber install failed — try manually: pip3 install pdfplumber"
fi

if "$PIP" install --quiet Pillow 2>/dev/null; then
    ok "Pillow installed (image auto-resize enabled)"
else
    info "Pillow not installed (optional)"
fi

# ---------------------------------------------------------------------------
hdr "[5/7] Downloading llamafile binary..."
# ---------------------------------------------------------------------------
LLAMAFILE_DEST="$TARGET/00_BOOT_SYSTEM/llamafile"

if [[ -x "$LLAMAFILE_DEST" ]]; then
    ok "llamafile already present — skipping download."
elif command -v curl &>/dev/null; then
    echo "  Downloading llamafile (~85 MB)..."
    if curl -L --progress-bar -o "$LLAMAFILE_DEST" "$LLAMAFILE_URL"; then
        chmod +x "$LLAMAFILE_DEST"
        SIZE="$(wc -c < "$LLAMAFILE_DEST")"
        ok "llamafile downloaded ($(( SIZE / 1048576 )) MB)"
    else
        warn "Download failed. Get it manually:"
        warn "  https://github.com/Mozilla-Ocho/llamafile/releases"
        warn "  Place as: $LLAMAFILE_DEST  (chmod +x)"
    fi
else
    warn "curl unavailable — skipping llamafile download."
    warn "  Get it from: https://github.com/Mozilla-Ocho/llamafile/releases"
fi

# ---------------------------------------------------------------------------
hdr "[6/7] Downloading llama-cli (CLI fallback)..."
# ---------------------------------------------------------------------------
LLAMA_CLI_DEST="$TARGET/00_BOOT_SYSTEM/bin/$PLATFORM/llama-cli"

if [[ -x "$LLAMA_CLI_DEST" ]]; then
    ok "llama-cli already present — skipping."
else
    # Try to get the latest release tag from GitHub
    LATEST_TAG=""
    if command -v curl &>/dev/null; then
        LATEST_TAG="$(curl -s "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" \
            2>/dev/null || true)"
    fi

    if [[ -n "$LATEST_TAG" ]]; then
        if [[ "$PLATFORM" == "linux" ]]; then
            ZIP_NAME="llama-${LATEST_TAG}-bin-ubuntu-x64.zip"
        else
            ZIP_NAME="llama-${LATEST_TAG}-bin-macos-arm64.zip"
        fi
        ZIP_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_TAG}/${ZIP_NAME}"
        TMP_ZIP="$(mktemp /tmp/llamacpp_XXXXXX.zip)"

        echo "  Downloading llama-cli $LATEST_TAG..."
        if curl -L --progress-bar -o "$TMP_ZIP" "$ZIP_URL" 2>/dev/null; then
            TMP_DIR="$(mktemp -d)"
            if command -v unzip &>/dev/null; then
                unzip -q "$TMP_ZIP" -d "$TMP_DIR"
                CLI_BIN="$(find "$TMP_DIR" -name 'llama-cli' -type f | head -n 1)"
                if [[ -n "$CLI_BIN" ]]; then
                    cp "$CLI_BIN" "$LLAMA_CLI_DEST"
                    chmod +x "$LLAMA_CLI_DEST"
                    ok "llama-cli installed ($LATEST_TAG)"
                else
                    warn "llama-cli binary not found in archive — install manually."
                fi
            else
                warn "unzip not available — install unzip and retry, or install llama-cli manually."
            fi
            rm -rf "$TMP_DIR" "$TMP_ZIP"
        else
            warn "llama-cli download failed. Get it manually:"
            warn "  https://github.com/ggerganov/llama.cpp/releases"
            rm -f "$TMP_ZIP"
        fi
    else
        warn "Could not determine latest llama.cpp version."
        warn "  Download llama-cli from: https://github.com/ggerganov/llama.cpp/releases"
        warn "  Place as: $LLAMA_CLI_DEST  (chmod +x)"
    fi
fi

# ---------------------------------------------------------------------------
hdr "[7/7] Running pre-flight check..."
# ---------------------------------------------------------------------------
echo ""
"$TARGET/00_BOOT_SYSTEM/setup_check.sh" --root "$TARGET" || true

# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=====================================================${NC}"
echo -e "${BOLD}  Setup complete.${NC}"
echo ""
echo "  NEXT STEPS (manual — models are too large to auto-download):"
echo ""
echo "  1. Download at least one language model:"
echo "     → Search huggingface.co for: Qwen2.5-7B-Instruct GGUF"
echo "       File: qwen2.5-7b-instruct-q4_k_m.gguf  (~4.7 GB)"
echo "       Place in: $TARGET/01_THE_BRAINS/"
echo ""
echo "     → Fallback (low-RAM machines): gemma-2-2b-it GGUF"
echo "       File: gemma-2-2b-it-q4_k_m.gguf  (~1.5 GB)"
echo "       Place in: $TARGET/01_THE_BRAINS/"
echo ""
echo "  2. Optional vision model:"
echo "     → Search huggingface.co for: moondream2 GGUF"
echo "       Download BOTH the model file AND the mmproj file"
echo "       Place BOTH in: $TARGET/04_THE_SCOUT/"
echo ""
echo "  3. Add your documents:"
echo "     → Copy PDFs/text files into $TARGET/03_THE_ARCHIVES/"
echo ""
echo "  4. Index documents:"
echo "     → python3 $TARGET/03_THE_ARCHIVES/convert_to_text.py --root $TARGET"
echo "     → python3 $TARGET/03_THE_ARCHIVES/index_archives.py --root $TARGET"
echo ""
echo "  5. First boot:"
echo "     → $TARGET/00_BOOT_SYSTEM/startup.sh --root $TARGET"
echo -e "${BOLD}=====================================================${NC}"
echo ""
