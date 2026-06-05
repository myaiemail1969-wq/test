#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Root Launcher (macOS)
# Drop this at the ROOT of the drive. Double-click in Finder to boot.
# =============================================================================

DRIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AERIA="$DRIVE_ROOT/aeria"
LAUNCHER="$AERIA/00_BOOT_SYSTEM/start-mac.command"

if [[ ! -f "$LAUNCHER" ]]; then
    echo ""
    echo "[ERROR] Cannot find aeria/ folder on this drive."
    echo "        Expected: $LAUNCHER"
    echo ""
    read -r -p "Press Enter to close..." _
    exit 1
fi

bash "$LAUNCHER"
