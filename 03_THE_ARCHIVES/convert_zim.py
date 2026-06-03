#!/usr/bin/env python3
# =============================================================================
# Project Aeria — ZIM Archive Converter
# Author:   Project Aeria
# Version:  1.0.0
# Purpose:  Extract article text from .zim files (Kiwix/Wikipedia offline
#           archives) into plain .txt files suitable for index_archives.py.
#           Each ZIM gets its own subdirectory under 03_THE_ARCHIVES/.
#           Resume-safe: skips articles already converted unless --overwrite.
# Usage:    python3 convert_zim.py --root /mnt/aeria
#           python3 convert_zim.py --root /mnt/aeria --zim wikipedia_en_medicine.zim
#           python3 convert_zim.py --root /mnt/aeria --dry-run --limit 100
# Requires: pip install libzim
# =============================================================================

from __future__ import annotations

import argparse
import re
import sys
from html.parser import HTMLParser
from pathlib import Path


# ---------------------------------------------------------------------------
# HTML → plain text
# ---------------------------------------------------------------------------

class _TextExtractor(HTMLParser):
    """Strip HTML tags and collect text runs from article HTML."""

    # Tags whose content we discard entirely
    _SKIP = {"script", "style", "head", "nav", "footer",
             "sup", "figure", "figcaption", "table", "cite"}

    # Tags that should produce a line break
    _BREAK = {"p", "br", "h1", "h2", "h3", "h4", "h5", "li",
              "dt", "dd", "tr", "blockquote", "pre"}

    def __init__(self) -> None:
        super().__init__()
        self._skip_depth = 0
        self._parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in self._SKIP:
            self._skip_depth += 1
        if tag in self._BREAK and self._skip_depth == 0:
            self._parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIP and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0:
            self._parts.append(data)

    def result(self) -> str:
        text = "".join(self._parts)
        # Collapse runs of whitespace-only lines
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


def html_to_text(raw: bytes) -> str:
    try:
        html = raw.decode("utf-8", errors="replace")
    except Exception:
        return ""
    parser = _TextExtractor()
    try:
        parser.feed(html)
    except Exception:
        pass
    return parser.result()


# ---------------------------------------------------------------------------
# Path / filename helpers
# ---------------------------------------------------------------------------

_MEDIA_EXT = re.compile(
    r"\.(png|jpg|jpeg|gif|svg|webp|css|js|json|xml|ogg|mp3|mp4|webm|pdf|ico|woff2?)$",
    re.IGNORECASE,
)

_SKIP_PREFIXES = ("I/", "-/", "X/", "M/", "images/", "assets/")


def _is_article(path: str) -> bool:
    """Return True if the ZIM entry path looks like an article (not media/meta)."""
    for pfx in _SKIP_PREFIXES:
        if path.startswith(pfx):
            return False
    if _MEDIA_EXT.search(path):
        return False
    return True


def _safe_name(title: str, path: str, max_len: int = 120) -> str:
    """Derive a safe filename from article title or path."""
    base = title.strip() if title.strip() else path.split("/")[-1]
    base = re.sub(r"[^\w\s\-]", "_", base)
    base = re.sub(r"\s+", "_", base).strip("_")
    return (base[:max_len] or "article") + ".txt"


# ---------------------------------------------------------------------------
# Core converter
# ---------------------------------------------------------------------------

def convert_zim(
    zim_path: Path,
    out_dir: Path,
    dry_run: bool = False,
    overwrite: bool = False,
    limit: int = 0,
    min_chars: int = 200,
    verbose: bool = False,
) -> tuple[int, int, int]:
    """
    Convert one ZIM file to plain text articles.
    Returns (converted, skipped, errors).
    """
    try:
        from libzim.reader import Archive  # type: ignore
    except ImportError:
        print("[ERROR] libzim not installed — run: pip install libzim", file=sys.stderr)
        sys.exit(1)

    article_dir = out_dir / zim_path.stem
    if not dry_run:
        article_dir.mkdir(parents=True, exist_ok=True)

    try:
        archive = Archive(str(zim_path))
    except Exception as exc:
        print(f"[ERROR] Cannot open {zim_path.name}: {exc}", file=sys.stderr)
        return 0, 0, 1

    total = archive.entry_count
    print(f"  ZIM      : {zim_path.name}")
    print(f"  Entries  : {total:,}")
    print(f"  Output   : {article_dir}")
    if dry_run:
        print("  Mode     : DRY RUN (no files written)")
    print()

    converted = skipped = errors = 0

    for idx in range(total):
        if limit and converted >= limit:
            break

        try:
            # VERIFY: libzim Python API varies by version.
            # libzim 3.x uses _get_entry_by_id; 4.x may use archive[idx].
            # If this raises AttributeError, try: entry = archive[idx]
            try:
                entry = archive._get_entry_by_id(idx)
            except AttributeError:
                entry = archive[idx]
        except Exception as exc:
            errors += 1
            if verbose:
                print(f"  [WARN] entry {idx}: {exc}")
            continue

        if entry.is_redirect:
            continue

        path  = getattr(entry, "path",  "") or ""
        title = getattr(entry, "title", "") or ""

        if not _is_article(path):
            continue

        fname    = _safe_name(title, path)
        out_path = article_dir / fname

        if out_path.exists() and not overwrite:
            skipped += 1
            continue

        try:
            item    = entry.get_item()
            content = bytes(item.content)
            text    = html_to_text(content)
        except Exception as exc:
            errors += 1
            if verbose:
                print(f"  [WARN] {path}: {exc}")
            continue

        if len(text) < min_chars:
            continue  # stub / redirect page

        if dry_run:
            if verbose:
                print(f"  [dry] {fname}  ({len(text):,} chars)")
        else:
            header = f"{title}\n{'=' * max(len(title), 4)}\n\n" if title else ""
            out_path.write_text(header + text + "\n", encoding="utf-8")

        converted += 1

        if converted % 5_000 == 0:
            pct = idx / total * 100
            print(f"  ... {converted:,} articles written  "
                  f"(entry {idx:,}/{total:,}, {pct:.0f}%)")

    return converted, skipped, errors


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        prog="convert_zim.py",
        description="Project Aeria — extract article text from ZIM archives",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Convert all .zim files in 03_THE_ARCHIVES/
  python3 convert_zim.py --root /mnt/aeria

  # Convert a specific ZIM file
  python3 convert_zim.py --root /mnt/aeria --zim wikipedia_en_medicine.zim

  # Preview first 200 articles without writing
  python3 convert_zim.py --root /mnt/aeria --dry-run --limit 200 --verbose

  # Re-convert everything (overwrite existing .txt files)
  python3 convert_zim.py --root /mnt/aeria --overwrite

After converting, run the indexer:
  python3 index_archives.py --root /mnt/aeria
""",
    )
    p.add_argument("--root",      default=None,
                   help="AERIA_ROOT (default: two levels above this script)")
    p.add_argument("--zim",       default=None,
                   help="Specific .zim filename to convert (looks in 03_THE_ARCHIVES/)")
    p.add_argument("--out",       default=None,
                   help="Output directory (default: 03_THE_ARCHIVES/)")
    p.add_argument("--dry-run",   action="store_true",
                   help="Report what would be written without creating files")
    p.add_argument("--overwrite", action="store_true",
                   help="Re-convert articles that already have a .txt file")
    p.add_argument("--limit",     type=int, default=0,
                   help="Max articles to convert per ZIM (0 = all)")
    p.add_argument("--min-chars", type=int, default=200,
                   help="Minimum text length to write (default 200, skips stubs)")
    p.add_argument("--verbose",   action="store_true",
                   help="Print each article as it's converted")
    args = p.parse_args()

    script_dir  = Path(__file__).resolve().parent
    aeria_root  = Path(args.root) if args.root else script_dir.parent
    archive_dir = Path(args.out)  if args.out  else aeria_root / "03_THE_ARCHIVES"

    if not archive_dir.exists():
        print(f"[ERROR] Archive directory not found: {archive_dir}", file=sys.stderr)
        sys.exit(1)

    # Collect ZIM files to process
    if args.zim:
        zim_path = archive_dir / args.zim
        if not zim_path.exists():
            print(f"[ERROR] ZIM file not found: {zim_path}", file=sys.stderr)
            sys.exit(1)
        zim_files = [zim_path]
    else:
        zim_files = sorted(archive_dir.glob("*.zim"))
        if not zim_files:
            print(f"[INFO] No .zim files found in {archive_dir}")
            print("       Download ZIM files from: https://library.kiwix.org")
            sys.exit(0)

    print()
    print("=" * 60)
    print("  Project Aeria — ZIM Converter")
    print(f"  Archive dir : {archive_dir}")
    print(f"  ZIM files   : {len(zim_files)}")
    print("=" * 60)
    print()

    total_converted = total_skipped = total_errors = 0

    for zim_path in zim_files:
        converted, skipped, errors = convert_zim(
            zim_path   = zim_path,
            out_dir    = archive_dir,
            dry_run    = args.dry_run,
            overwrite  = args.overwrite,
            limit      = args.limit,
            min_chars  = args.min_chars,
            verbose    = args.verbose,
        )
        total_converted += converted
        total_skipped   += skipped
        total_errors    += errors

        status = "dry-run" if args.dry_run else "converted"
        print(f"  Done: {converted:,} {status}, {skipped:,} skipped, {errors:,} errors")
        print()

    print("=" * 60)
    print(f"  Total converted : {total_converted:,}")
    print(f"  Total skipped   : {total_skipped:,}")
    print(f"  Total errors    : {total_errors:,}")
    print()
    if not args.dry_run and total_converted > 0:
        print("  Next step:")
        print(f"    python3 {aeria_root}/03_THE_ARCHIVES/index_archives.py --root {aeria_root}")
    print("=" * 60)
    print()


if __name__ == "__main__":
    main()
