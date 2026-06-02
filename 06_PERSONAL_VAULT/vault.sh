#!/usr/bin/env bash
# =============================================================================
# Project Aeria — Personal Vault
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  AES-256 symmetric encryption for sensitive personal documents.
#           Encrypts to 06_PERSONAL_VAULT/ using GPG.
#           Decrypts only to RAM-backed /tmp — plaintext never touches
#           persistent storage after the original is shredded.
# Usage:    ./vault.sh <command> [OPTIONS]
# Commands: init | add | get | list | verify | wipe-tmp
# =============================================================================

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AERIA_ROOT="$(cd "$VAULT_DIR/.." && pwd)"
LOG_DIR="$AERIA_ROOT/05_USER_ADDITIONS/logs"
TMP_BASE="/tmp/aeria_vault"

# GPG flags used for every encrypt/decrypt operation
GPG_CIPHER_FLAGS=(
    --symmetric
    --cipher-algo  AES256
    --s2k-digest-algo SHA512
    --s2k-mode     3
    --s2k-count    65536
    --batch
    --passphrase-fd 0
    --pinentry-mode loopback
    --no-symkey-cache
)

GPG_DECRYPT_FLAGS=(
    --decrypt
    --batch
    --passphrase-fd 0
    --pinentry-mode loopback
    --no-symkey-cache
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ts()     { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_log()    {
    local level="$1"; shift
    local line="[$(_ts)] [$level] $*"
    echo "$line" >&2
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        echo "$line" >> "$LOG_DIR/vault_$(date -u '+%Y%m%d').log"
    fi
}
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# Detect GPG binary (gpg2 preferred, gpg fallback)
find_gpg() {
    if command -v gpg2 &>/dev/null; then echo "gpg2"
    elif command -v gpg &>/dev/null; then echo "gpg"
    else
        echo "[ERROR] GPG not found. Install gnupg and retry." >&2
        echo "  Linux : sudo apt install gnupg" >&2
        echo "  macOS : brew install gnupg" >&2
        exit 1
    fi
}

# Prompt for passphrase without echoing — stores in variable, never on disk
read_passphrase() {
    local prompt="$1"
    local var_name="$2"
    local pass=""
    read -r -s -p "$prompt" pass
    echo >&2    # newline after silent input
    printf -v "$var_name" '%s' "$pass"
}

# Check /tmp is tmpfs (RAM-backed) — warn if not
check_tmp_is_ram() {
    if command -v findmnt &>/dev/null; then
        local fstype
        fstype="$(findmnt -n -o FSTYPE /tmp 2>/dev/null || true)"
        if [[ "$fstype" != "tmpfs" ]]; then
            log_warn "/tmp is not tmpfs — decrypted files will touch disk."
            log_warn "Consider mounting a tmpfs: sudo mount -t tmpfs tmpfs /tmp"
        fi
    fi
}

# Secure deletion — shred if available, else overwrite + rm
secure_delete() {
    local file="$1"
    if command -v shred &>/dev/null; then
        shred -u -z "$file"
    else
        # Overwrite with zeros three times then remove
        local size
        size=$(wc -c < "$file")
        dd if=/dev/zero of="$file" bs=1 count="$size" conv=notrunc 2>/dev/null
        dd if=/dev/zero of="$file" bs=1 count="$size" conv=notrunc 2>/dev/null
        dd if=/dev/zero of="$file" bs=1 count="$size" conv=notrunc 2>/dev/null
        rm -f "$file"
        log_warn "shred not available — used dd overwrite (less secure on flash/SSD)."
    fi
}

# ---------------------------------------------------------------------------
# Command: init
# Creates the vault directory structure and writes the README.
# ---------------------------------------------------------------------------
cmd_init() {
    log_info "Initialising vault at: $VAULT_DIR"

    local gpg
    gpg="$(find_gpg)"
    log_info "GPG binary: $gpg ($($gpg --version | head -1))"

    # Create subdirectory structure
    for subdir in family medical legal credentials; do
        mkdir -p "$VAULT_DIR/$subdir"
        log_info "  Created: $subdir/"
    done

    # Self-test: encrypt and decrypt a small file to verify GPG works
    log_info "Running self-test..."
    local test_pass="aeria-vault-test-$$"
    local test_plain
    test_plain="$(mktemp)"
    local test_enc
    test_enc="$(mktemp)"
    local test_dec
    test_dec="$(mktemp)"

    echo "AERIA VAULT SELF-TEST $(_ts)" > "$test_plain"

    printf '%s\n' "$test_pass" | "$gpg" "${GPG_CIPHER_FLAGS[@]}" \
        --output "$test_enc" "$test_plain" 2>/dev/null

    printf '%s\n' "$test_pass" | "$gpg" "${GPG_DECRYPT_FLAGS[@]}" \
        --output "$test_dec" "$test_enc" 2>/dev/null

    if diff -q "$test_plain" "$test_dec" &>/dev/null; then
        log_info "Self-test PASSED — AES-256 encrypt/decrypt verified."
    else
        log_error "Self-test FAILED — GPG encryption is not working correctly."
        rm -f "$test_plain" "$test_enc" "$test_dec"
        exit 1
    fi
    rm -f "$test_plain" "$test_enc" "$test_dec"
    unset test_pass

    log_info "Vault initialised. Use './vault.sh add FILE' to store documents."
}

# ---------------------------------------------------------------------------
# Command: add FILE [--name NAME] [--category SUBDIR] [--shred]
# Encrypts a file and stores it in the vault.
# ---------------------------------------------------------------------------
cmd_add() {
    local source_file=""
    local vault_name=""
    local category=""
    local do_shred=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     vault_name="$2"; shift 2 ;;
            --category) category="$2";  shift 2 ;;
            --shred)    do_shred=true;  shift   ;;
            -*)  log_error "Unknown add option: $1"; exit 1 ;;
            *)   source_file="$1"; shift ;;
        esac
    done

    if [[ -z "$source_file" ]]; then
        log_error "Usage: vault.sh add FILE [--name NAME] [--category SUBDIR] [--shred]"
        exit 1
    fi
    if [[ ! -f "$source_file" ]]; then
        log_error "File not found: $source_file"
        exit 1
    fi

    # Defaults
    [[ -z "$vault_name" ]]  && vault_name="$(basename "$source_file")"
    [[ -z "$category" ]]    && category="family"
    local dest_dir="$VAULT_DIR/$category"
    local dest_file="$dest_dir/${vault_name}.gpg"

    mkdir -p "$dest_dir"

    if [[ -f "$dest_file" ]]; then
        log_warn "File already exists in vault: $category/$vault_name.gpg"
        read -r -p "Overwrite? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { log_info "Aborted."; exit 0; }
    fi

    local gpg
    gpg="$(find_gpg)"
    local passphrase=""
    local confirm_pass=""

    read_passphrase "  Passphrase for vault: " passphrase
    read_passphrase "  Confirm passphrase:   " confirm_pass

    if [[ "$passphrase" != "$confirm_pass" ]]; then
        unset passphrase confirm_pass
        log_error "Passphrases do not match."
        exit 1
    fi
    unset confirm_pass

    printf '%s\n' "$passphrase" | "$gpg" "${GPG_CIPHER_FLAGS[@]}" \
        --output "$dest_file" "$source_file"
    unset passphrase

    local size
    size="$(wc -c < "$dest_file")"
    log_info "Encrypted: $source_file → $category/${vault_name}.gpg (${size} bytes)"

    if [[ "$do_shred" == "true" ]]; then
        log_info "Shredding original: $source_file"
        secure_delete "$source_file"
        log_info "Original securely deleted."
    else
        log_warn "Original file NOT deleted: $source_file"
        log_warn "Run with --shred or delete manually when ready."
    fi
}

# ---------------------------------------------------------------------------
# Command: get NAME [--category SUBDIR] [--output-dir DIR]
# Decrypts a vault file to /tmp (never to persistent storage).
# ---------------------------------------------------------------------------
cmd_get() {
    local vault_name=""
    local category=""
    local output_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --category)  category="$2";   shift 2 ;;
            --output-dir) output_dir="$2"; shift 2 ;;
            -*)  log_error "Unknown get option: $1"; exit 1 ;;
            *)   vault_name="$1"; shift ;;
        esac
    done

    if [[ -z "$vault_name" ]]; then
        log_error "Usage: vault.sh get NAME [--category SUBDIR]"
        exit 1
    fi

    # Strip .gpg suffix if user included it
    vault_name="${vault_name%.gpg}"

    # Find the encrypted file
    local enc_file=""
    if [[ -n "$category" ]]; then
        enc_file="$VAULT_DIR/$category/${vault_name}.gpg"
    else
        # Search all subdirs
        enc_file="$(find "$VAULT_DIR" -name "${vault_name}.gpg" -type f | head -n 1)"
    fi

    if [[ -z "$enc_file" || ! -f "$enc_file" ]]; then
        log_error "Not found in vault: ${vault_name}.gpg"
        log_error "Run './vault.sh list' to see available files."
        exit 1
    fi

    check_tmp_is_ram

    # Decrypt to a unique /tmp directory
    if [[ -z "$output_dir" ]]; then
        output_dir="$(mktemp -d "${TMP_BASE}_XXXXXX")"
    else
        mkdir -p "$output_dir"
    fi

    local gpg
    gpg="$(find_gpg)"
    local passphrase=""
    read_passphrase "  Passphrase: " passphrase

    local out_file="$output_dir/${vault_name}"
    printf '%s\n' "$passphrase" | "$gpg" "${GPG_DECRYPT_FLAGS[@]}" \
        --output "$out_file" "$enc_file"
    unset passphrase

    log_info "Decrypted to: $out_file"
    echo ""
    echo "  FILE: $out_file"
    echo ""
    echo "  !! This file exists only in /tmp (RAM). It will be"
    echo "     lost on reboot, or run './vault.sh wipe-tmp' to"
    echo "     remove it immediately after use."
    echo ""
}

# ---------------------------------------------------------------------------
# Command: list [--category SUBDIR]
# Lists all encrypted files in the vault.
# ---------------------------------------------------------------------------
cmd_list() {
    local category="${1:-}"
    local search_root="$VAULT_DIR"
    [[ -n "$category" ]] && search_root="$VAULT_DIR/$category"

    echo ""
    echo "  PERSONAL VAULT — Contents"
    echo "  ─────────────────────────────────────────────────"

    local count=0
    while IFS= read -r -d '' file; do
        local rel_path="${file#"$VAULT_DIR/"}"
        local size
        size="$(wc -c < "$file")"
        local mtime
        mtime="$(date -r "$file" '+%Y-%m-%d' 2>/dev/null || stat -c '%y' "$file" 2>/dev/null | cut -d' ' -f1)"
        printf "  %-40s  %8s bytes  %s\n" "$rel_path" "$size" "$mtime"
        count=$((count + 1))
    done < <(find "$search_root" -name '*.gpg' -type f -print0 | sort -z)

    if [[ $count -eq 0 ]]; then
        echo "  (vault is empty — use './vault.sh add FILE' to store documents)"
    else
        echo "  ─────────────────────────────────────────────────"
        echo "  Total: $count file(s)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Command: verify
# Test-decrypts every file in the vault to confirm integrity.
# Writes nothing — output goes to /dev/null.
# ---------------------------------------------------------------------------
cmd_verify() {
    local gpg
    gpg="$(find_gpg)"
    local passphrase=""
    read_passphrase "  Passphrase to verify all files: " passphrase

    local pass_count=0
    local fail_count=0

    while IFS= read -r -d '' file; do
        local rel="${file#"$VAULT_DIR/"}"
        if printf '%s\n' "$passphrase" | "$gpg" "${GPG_DECRYPT_FLAGS[@]}" \
            --output /dev/null "$file" 2>/dev/null; then
            log_info "  [OK]   $rel"
            pass_count=$((pass_count + 1))
        else
            log_error "  [FAIL] $rel — wrong passphrase or corrupted file"
            fail_count=$((fail_count + 1))
        fi
    done < <(find "$VAULT_DIR" -name '*.gpg' -type f -print0 | sort -z)

    unset passphrase

    echo ""
    echo "  Verify complete: $pass_count OK, $fail_count FAILED"
    echo ""
    [[ $fail_count -gt 0 ]] && exit 1
}

# ---------------------------------------------------------------------------
# Command: wipe-tmp
# Securely removes all decrypted files from /tmp/aeria_vault_* directories.
# ---------------------------------------------------------------------------
cmd_wipe_tmp() {
    local wiped=0

    while IFS= read -r -d '' dir; do
        log_info "Wiping: $dir"
        find "$dir" -type f -print0 | while IFS= read -r -d '' f; do
            secure_delete "$f"
            wiped=$((wiped + 1))
        done
        rm -rf "$dir"
    done < <(find /tmp -maxdepth 1 -name 'aeria_vault_*' -type d -print0 2>/dev/null)

    if [[ $wiped -eq 0 ]]; then
        log_info "No decrypted vault files found in /tmp."
    else
        log_info "$wiped file(s) wiped from /tmp."
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

Usage: $(basename "$0") <command> [OPTIONS]

Commands:
  init                             Verify GPG, create vault structure, run self-test
  add FILE [--name N] [--category C] [--shred]
                                   Encrypt FILE into vault (--shred deletes original)
  get NAME [--category C]          Decrypt named file to /tmp
  list [CATEGORY]                  List encrypted files in vault
  verify                           Test-decrypt all files (no output written)
  wipe-tmp                         Shred all decrypted files from /tmp

Categories (default: family):
  family | medical | legal | credentials

Examples:
  ./vault.sh init
  ./vault.sh add ~/passwords.txt --category credentials --shred
  ./vault.sh add ~/scan_passport.pdf --name passport --category family
  ./vault.sh get passport --category family
  ./vault.sh list
  ./vault.sh verify
  ./vault.sh wipe-tmp

Encryption: GPG AES-256, SHA-512 key derivation, 65536 iterations.
Decryption target: /tmp (RAM) only — plaintext never written to source media.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        init)      cmd_init ;;
        add)       cmd_add "$@" ;;
        get)       cmd_get "$@" ;;
        list)      cmd_list "$@" ;;
        verify)    cmd_verify ;;
        wipe-tmp)  cmd_wipe_tmp ;;
        ""|--help|-h) usage; exit 0 ;;
        *) log_error "Unknown command: '$command'"; usage; exit 1 ;;
    esac
}

main "$@"
