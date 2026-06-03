#!/usr/bin/env python3
# =============================================================================
# Project Aeria — Reference Downloader
# Author:   Project Aeria
# Version:  1.0.0
# Purpose:  Downloads free reference PDFs (field manuals, medical guides,
#           textbooks) from the curated manifest in aeria_downloads.json.
#           Resume-safe: skips completed downloads, retries failures.
#           All sources are public domain or freely licensed for personal use.
# Usage:    python3 download_references.py --root /mnt/aeria
#           python3 download_references.py --root /mnt/aeria --category medical
#           python3 download_references.py --root /mnt/aeria --dry-run
# =============================================================================

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

CHUNK   = 65_536       # 64 KB read chunks
TIMEOUT = 60           # seconds per request
RETRIES = 3
BACKOFF = (2, 4, 8)    # seconds between retries


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def download_file(
    url: str,
    dest: Path,
    name: str,
    verify: str = "",
) -> bool:
    """
    Download url → dest with progress bar and retry logic.
    Returns True on success, False on permanent failure.
    """
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (compatible; ProjectAeria/1.0; "
            "offline reference downloader)"
        )
    }

    for attempt in range(1, RETRIES + 1):
        try:
            req  = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                total = int(resp.headers.get("Content-Length", 0))
                received = 0
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_suffix(".part")
                with open(tmp, "wb") as fh:
                    while True:
                        chunk = resp.read(CHUNK)
                        if not chunk:
                            break
                        fh.write(chunk)
                        received += len(chunk)
                        if total:
                            pct = received / total * 100
                            bar = "#" * int(pct / 5)
                            print(
                                f"\r    [{bar:<20}] {pct:5.1f}%  "
                                f"{_human_size(received)}/{_human_size(total)}   ",
                                end="", flush=True,
                            )
                print()  # newline after progress bar
                tmp.rename(dest)
                return True

        except urllib.error.HTTPError as exc:
            print(f"\n  [HTTP {exc.code}] {name}")
            if exc.code in (403, 404, 410):
                # Permanent failure — don't retry
                if verify:
                    print(f"  [HINT] {verify}")
                return False
            # Transient error — fall through to retry

        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            print(f"\n  [WARN] attempt {attempt}/{RETRIES}: {exc}")

        if attempt < RETRIES:
            wait = BACKOFF[attempt - 1]
            print(f"  Retrying in {wait}s...")
            time.sleep(wait)

    print(f"  [FAIL] {name} — all {RETRIES} attempts failed.")
    if verify:
        print(f"  [HINT] {verify}")
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        prog="download_references.py",
        description="Project Aeria — download free reference documents",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Download everything in the manifest
  python3 download_references.py --root /mnt/aeria

  # Download only medical category
  python3 download_references.py --root /mnt/aeria --category medical

  # Preview what would be downloaded
  python3 download_references.py --root /mnt/aeria --dry-run

  # Re-download everything (overwrite existing)
  python3 download_references.py --root /mnt/aeria --force

After downloading, convert and index:
  python3 convert_to_text.py --root /mnt/aeria
  python3 index_archives.py  --root /mnt/aeria
""",
    )
    p.add_argument("--root",      default=None,
                   help="AERIA_ROOT (default: two levels above this script)")
    p.add_argument("--manifest",  default=None,
                   help="Path to JSON manifest (default: aeria_downloads.json)")
    p.add_argument("--category",  default=None,
                   help="Only download this category (medical/survival/engineering/reference)")
    p.add_argument("--dry-run",   action="store_true",
                   help="List what would be downloaded without fetching")
    p.add_argument("--force",     action="store_true",
                   help="Re-download files that already exist")
    p.add_argument("--list",      action="store_true",
                   help="List all available categories and files")
    args = p.parse_args()

    script_dir   = Path(__file__).resolve().parent
    aeria_root   = Path(args.root) if args.root else script_dir.parent
    archive_dir  = aeria_root / "03_THE_ARCHIVES"
    manifest_path = (
        Path(args.manifest) if args.manifest
        else script_dir / "aeria_downloads.json"
    )

    if not manifest_path.exists():
        print(f"[ERROR] Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    try:
        entries = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"[ERROR] Invalid JSON in manifest: {exc}", file=sys.stderr)
        sys.exit(1)

    # Filter by category
    if args.category:
        entries = [e for e in entries
                   if e.get("category", "").lower() == args.category.lower()]
        if not entries:
            cats = sorted({e.get("category","") for e in
                          json.loads(manifest_path.read_text())})
            print(f"[ERROR] No entries for category '{args.category}'.")
            print(f"  Available: {', '.join(cats)}")
            sys.exit(1)

    # --list mode
    if args.list:
        from collections import defaultdict
        by_cat: dict = defaultdict(list)
        for e in json.loads(manifest_path.read_text()):
            by_cat[e.get("category", "other")].append(e)
        for cat, items in sorted(by_cat.items()):
            print(f"\n  [{cat.upper()}]")
            for item in items:
                dest = archive_dir / "downloads" / cat / item["filename"]
                status = "✓" if dest.exists() else "·"
                print(f"    {status} {item['name']}")
                print(f"        {item['description']}")
        print()
        sys.exit(0)

    # Header
    print()
    print("=" * 60)
    print("  Project Aeria — Reference Downloader")
    print(f"  Output  : {archive_dir / 'downloads'}")
    print(f"  Entries : {len(entries)}")
    if args.dry_run:
        print("  Mode    : DRY RUN")
    print("=" * 60)
    print()

    ok = skipped = failed = 0

    for entry in entries:
        name     = entry.get("name", "Unknown")
        url      = entry.get("url", "")
        filename = entry.get("filename", "")
        category = entry.get("category", "misc")
        desc     = entry.get("description", "")
        verify   = entry.get("verify", "")

        if not url or not filename:
            print(f"  [SKIP] Incomplete entry: {name}")
            continue

        dest = archive_dir / "downloads" / category / filename

        print(f"  {name}")
        print(f"  {desc}")

        if dest.exists() and not args.force:
            size = _human_size(dest.stat().st_size)
            print(f"  [OK] Already downloaded ({size}) — use --force to re-download")
            skipped += 1
            print()
            continue

        if args.dry_run:
            print(f"  [dry] Would download → {dest}")
            print(f"        {url}")
            print()
            ok += 1
            continue

        print(f"  Downloading from: {url}")
        print(f"  Saving to       : {dest}")
        success = download_file(url, dest, name, verify)
        if success:
            size = _human_size(dest.stat().st_size)
            print(f"  [OK] {size}")
            ok += 1
        else:
            failed += 1
        print()

    # Summary
    print("=" * 60)
    print(f"  Downloaded : {ok}")
    print(f"  Skipped    : {skipped}  (already present)")
    print(f"  Failed     : {failed}")
    print()
    if not args.dry_run and ok > 0:
        print("  Next steps:")
        print(f"    python3 {script_dir}/convert_to_text.py --root {aeria_root}")
        print(f"    python3 {script_dir}/index_archives.py  --root {aeria_root}")
    print("=" * 60)
    print()

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
