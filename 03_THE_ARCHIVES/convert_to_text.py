#!/usr/bin/env python3
# =============================================================================
# Project Aeria — PDF to Text Converter
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Bulk-converts PDFs (and other documents) in 03_THE_ARCHIVES/ to
#           clean plain text (.txt) or lightly structured Markdown (.md).
#           Plain text is 5-20x smaller than PDF and feeds directly into the
#           FTS5 index with zero parsing overhead.
#           Run this before index_archives.py to get the best ingest quality.
# Usage:    python3 convert_to_text.py [OPTIONS]
# =============================================================================

from __future__ import annotations

import argparse
import logging
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# PDF backend — same precedence chain as index_archives.py
# ---------------------------------------------------------------------------
_PDF_BACKEND: str | None = None

try:
    import pdfplumber  # type: ignore
    _PDF_BACKEND = "pdfplumber"
except ImportError:
    pass

if _PDF_BACKEND is None:
    try:
        import pypdf  # type: ignore
        _PDF_BACKEND = "pypdf"
    except ImportError:
        pass

if _PDF_BACKEND is None:
    try:
        import PyPDF2  # type: ignore
        _PDF_BACKEND = "PyPDF2"
    except ImportError:
        pass

SOURCE_EXTS  = {".pdf"}
OUTPUT_EXTS  = {".txt", ".md"}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(log_dir: Path, verbose: bool) -> logging.Logger:
    log_dir.mkdir(parents=True, exist_ok=True)
    ts       = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    log_path = log_dir / f"convert_{ts}.log"
    fmt      = "[%(asctime)s] [%(levelname)-5s] %(message)s"
    datefmt  = "%Y-%m-%dT%H:%M:%SZ"
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format=fmt, datefmt=datefmt,
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    log = logging.getLogger("aeria.convert")
    log.info("Log: %s", log_path)
    return log


# ---------------------------------------------------------------------------
# PDF extraction
# ---------------------------------------------------------------------------

def extract_pages(path: Path, log: logging.Logger) -> list[tuple[int, str]]:
    """
    Extract text from a PDF. Returns [(page_num_1indexed, text), ...].
    Empty and whitespace-only pages are omitted.
    """
    pages: list[tuple[int, str]] = []

    if _PDF_BACKEND == "pdfplumber":
        import pdfplumber  # type: ignore
        try:
            with pdfplumber.open(path) as pdf:
                for i, page in enumerate(pdf.pages, 1):
                    text = page.extract_text() or ""
                    if text.strip():
                        pages.append((i, text))
        except Exception as exc:
            log.warning("pdfplumber failed on '%s': %s", path.name, exc)

    elif _PDF_BACKEND == "pypdf":
        import pypdf  # type: ignore
        try:
            reader = pypdf.PdfReader(str(path))
            for i, page in enumerate(reader.pages, 1):
                text = page.extract_text() or ""
                if text.strip():
                    pages.append((i, text))
        except Exception as exc:
            log.warning("pypdf failed on '%s': %s", path.name, exc)

    elif _PDF_BACKEND == "PyPDF2":
        import PyPDF2  # type: ignore
        try:
            with open(path, "rb") as f:
                reader = PyPDF2.PdfReader(f)
                for i, page in enumerate(reader.pages, 1):
                    text = page.extract_text() or ""
                    if text.strip():
                        pages.append((i, text))
        except Exception as exc:
            log.warning("PyPDF2 failed on '%s': %s", path.name, exc)

    else:
        log.error("No PDF library installed. Install pdfplumber or pypdf.")

    return pages


# ---------------------------------------------------------------------------
# Text cleaning pipeline
# ---------------------------------------------------------------------------

# Matches soft hyphens at line ends (word-wrap artifact from PDF layout)
_HYPHEN_WRAP = re.compile(r"-\n([a-z])")
# Collapse lines that are clearly continuations (no capital + not blank)
_SOFT_NEWLINE = re.compile(r"(?<!\n)\n(?!\n)(?![A-Z\d•\-–—])")
# Three or more blank lines → two
_EXCESS_BLANK = re.compile(r"\n{3,}")
# Trailing whitespace on each line
_TRAILING_WS  = re.compile(r"[ \t]+$", re.MULTILINE)
# Common PDF page-number patterns: standalone digits or "Page N of M"
_PAGE_NUMBER  = re.compile(r"^\s*(?:Page\s+)?\d+\s*(?:of\s+\d+)?\s*$", re.IGNORECASE | re.MULTILINE)
# Lone single-character lines (common OCR noise)
_LONE_CHAR    = re.compile(r"^\s*[^\w\s]\s*$", re.MULTILINE)


def clean_text(raw: str) -> str:
    """
    Apply a cleaning pipeline to raw PDF-extracted text.
    Order matters — each step builds on the previous.
    """
    text = raw
    # 1. Fix hyphenated word-wrap ("hyph-\nation" → "hyphenation")
    text = _HYPHEN_WRAP.sub(r"\1", text)
    # 2. Rejoin soft-wrapped lines into paragraphs
    text = _SOFT_NEWLINE.sub(" ", text)
    # 3. Remove standalone page numbers
    text = _PAGE_NUMBER.sub("", text)
    # 4. Remove lone punctuation lines (OCR noise)
    text = _LONE_CHAR.sub("", text)
    # 5. Strip trailing whitespace from each line
    text = _TRAILING_WS.sub("", text)
    # 6. Normalise excessive blank lines
    text = _EXCESS_BLANK.sub("\n\n", text)
    # 7. Final strip
    return text.strip()


# ---------------------------------------------------------------------------
# Markdown header detection
# ---------------------------------------------------------------------------

# Patterns that strongly suggest a line is a section heading
_HEADER_PATTERNS = [
    re.compile(r"^(chapter|section|appendix|part|unit|module)\s+[\divxlc]+", re.IGNORECASE),
    re.compile(r"^\d+\.\s+[A-Z][A-Za-z\s]{3,50}$"),       # "1. Introduction"
    re.compile(r"^\d+\.\d+\s+[A-Z][A-Za-z\s]{3,50}$"),    # "2.3 Subsection"
]


def _looks_like_header(line: str) -> bool:
    """
    Heuristic: return True if the line is likely a section heading.
    Conservative — prefers false negatives over false positives.
    """
    stripped = line.strip()
    if not stripped or len(stripped) > 80:
        return False
    # Must not end with sentence-terminating punctuation
    if stripped[-1] in ".,:;?!":
        return False
    # Must not look like a list item
    if stripped.startswith(("•", "-", "*", "–", "—")):
        return False

    for pat in _HEADER_PATTERNS:
        if pat.match(stripped):
            return True

    # ALL CAPS short line (e.g. "TREATMENT PROTOCOL")
    words = stripped.split()
    if (3 <= len(words) <= 8
            and all(w.isupper() or not w.isalpha() for w in words)
            and any(w.isalpha() for w in words)):
        return True

    return False


def _header_level(line: str) -> int:
    """Return Markdown heading level (1-3) based on line characteristics."""
    stripped = line.strip()
    # "Chapter N" or "Part N" → H1
    if re.match(r"^(chapter|part)\s+", stripped, re.IGNORECASE):
        return 1
    # "1. Title" → H2
    if re.match(r"^\d+\.\s+", stripped):
        return 2
    # "1.1 Subtitle" or ALL CAPS → H3
    return 3


def text_to_markdown(text: str, source_name: str) -> str:
    """
    Convert cleaned plain text to lightly structured Markdown.
    Inserts heading markers where heuristics detect section titles.
    Preserves paragraphs and list-like lines.
    """
    lines   = text.splitlines()
    output  = [f"# {source_name}", ""]
    prev_blank = True   # treat start-of-doc as preceded by blank

    for line in lines:
        stripped = line.strip()
        is_blank = not stripped

        if is_blank:
            output.append("")
            prev_blank = True
            continue

        # Only promote to heading if preceded by a blank line (paragraph break)
        if prev_blank and _looks_like_header(stripped):
            level = _header_level(stripped)
            output.append(f"{'#' * level} {stripped}")
        else:
            output.append(line)

        prev_blank = False

    return "\n".join(output).strip()


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------

def output_path_for(
    source: Path,
    archives_root: Path,
    output_root: Path | None,
    fmt: str,
) -> Path:
    """
    Compute the output file path. Mirrors the source directory structure
    under output_root (or alongside the source file if output_root is None).
    """
    stem = source.stem
    ext  = f".{fmt}"
    if output_root is None:
        return source.parent / f"{stem}{ext}"
    rel  = source.relative_to(archives_root)
    return output_root / rel.parent / f"{stem}{ext}"


def convert_file(
    source: Path,
    archives_root: Path,
    output_root: Path | None,
    fmt: str,
    overwrite: bool,
    log: logging.Logger,
) -> dict:
    """
    Convert a single PDF to text or Markdown.
    Returns a stats dict: {status, pages, chars, out_path}.
    """
    dest = output_path_for(source, archives_root, output_root, fmt)

    if dest.exists() and not overwrite:
        log.debug("  SKIP (exists): %s", dest.name)
        return {"status": "skipped", "pages": 0, "chars": 0, "out_path": dest}

    pages = extract_pages(source, log)
    if not pages:
        log.warning("  NO TEXT: %s — skipping.", source.name)
        return {"status": "no_text", "pages": 0, "chars": 0, "out_path": dest}

    # Assemble full document text with page separators
    sections: list[str] = []
    for page_num, page_text in pages:
        cleaned = clean_text(page_text)
        if cleaned:
            sections.append(cleaned)

    full_text = "\n\n".join(sections)

    if fmt == "md":
        output_text = text_to_markdown(full_text, source.stem.replace("_", " ").replace("-", " ").title())
    else:
        output_text = full_text

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(output_text, encoding="utf-8")

    stats = {
        "status":   "converted",
        "pages":    len(pages),
        "chars":    len(output_text),
        "out_path": dest,
    }
    size_kb = dest.stat().st_size / 1024
    src_kb  = source.stat().st_size / 1024
    ratio   = src_kb / size_kb if size_kb > 0 else 0
    log.info(
        "  %s → %s  (%d pages, %.1f KB → %.1f KB, %.1fx smaller)",
        source.name, dest.name, len(pages), src_kb, size_kb, ratio,
    )
    return stats


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="convert_to_text.py",
        description="Project Aeria — PDF to Text Converter",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Convert all PDFs in archives to .txt alongside originals:
    python3 convert_to_text.py --root /mnt/aeria

  Convert to Markdown, write to a separate output directory:
    python3 convert_to_text.py --root /mnt/aeria --format md --output-dir /mnt/aeria/03_THE_ARCHIVES/converted

  Preview what would be converted without doing it:
    python3 convert_to_text.py --root /mnt/aeria --dry-run

  Re-convert files that already have a .txt (overwrite):
    python3 convert_to_text.py --root /mnt/aeria --overwrite

After converting, run index_archives.py to build the search index.
PDF libraries (install one):
    pip install pdfplumber    # recommended
    pip install pypdf
""",
    )
    p.add_argument("--root",       default=None,
                   help="AERIA_ROOT path (default: two levels above this script)")
    p.add_argument("--input-dir",  default=None, metavar="DIR",
                   help="Source directory to scan (default: 03_THE_ARCHIVES/)")
    p.add_argument("--output-dir", default=None, metavar="DIR",
                   help="Where to write converted files (default: alongside source PDFs)")
    p.add_argument("--format",     choices=["txt", "md"], default="txt",
                   help="Output format: txt (smallest) or md (with headers) (default: txt)")
    p.add_argument("--overwrite",  action="store_true",
                   help="Re-convert files that already have a .txt/.md output")
    p.add_argument("--dry-run",    action="store_true",
                   help="Show what would be converted without writing any files")
    p.add_argument("--verbose",    action="store_true",
                   help="Enable DEBUG logging")
    return p


def main() -> None:
    args   = build_parser().parse_args()

    script_dir   = Path(__file__).resolve().parent
    aeria_root   = Path(args.root) if args.root else script_dir.parent
    archives_dir = Path(args.input_dir) if args.input_dir else (aeria_root / "03_THE_ARCHIVES")
    output_root  = Path(args.output_dir) if args.output_dir else None
    log_dir      = aeria_root / "05_USER_ADDITIONS" / "logs"

    log = setup_logging(log_dir, args.verbose)
    log.info("AERIA_ROOT   : %s", aeria_root)
    log.info("Source dir   : %s", archives_dir)
    log.info("Output dir   : %s", output_root or "(alongside source)")
    log.info("Format       : .%s", args.format)
    log.info("PDF backend  : %s", _PDF_BACKEND or "NONE — install pdfplumber or pypdf")

    if not archives_dir.is_dir():
        log.error("Source directory not found: %s", archives_dir)
        sys.exit(1)

    if _PDF_BACKEND is None:
        log.error("No PDF library installed. Cannot convert PDFs.")
        log.error("  pip install pdfplumber   # recommended")
        log.error("  pip install pypdf")
        sys.exit(1)

    # Discover source files — skip files that are already converted output
    source_files = sorted(
        p for p in archives_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in SOURCE_EXTS
    )

    if not source_files:
        log.warning("No PDF files found in %s", archives_dir)
        sys.exit(0)

    log.info("PDFs found   : %d", len(source_files))

    if args.dry_run:
        log.info("DRY RUN — no files will be written.")
        for p in source_files:
            dest = output_path_for(p, archives_dir, output_root, args.format)
            status = "SKIP (exists)" if dest.exists() else "CONVERT"
            src_kb = p.stat().st_size / 1024
            print(f"  [{status:14s}] {p.relative_to(archives_dir)}  ({src_kb:.0f} KB)")
        return

    # Convert
    totals = {"converted": 0, "skipped": 0, "no_text": 0,
              "failed": 0, "pages": 0, "chars": 0}

    for path in source_files:
        try:
            result = convert_file(
                source=path,
                archives_root=archives_dir,
                output_root=output_root,
                fmt=args.format,
                overwrite=args.overwrite,
                log=log,
            )
            totals[result["status"]] = totals.get(result["status"], 0) + 1
            totals["pages"] += result["pages"]
            totals["chars"] += result["chars"]
        except Exception as exc:
            log.error("FAILED: %s — %s", path.name, exc, exc_info=args.verbose)
            totals["failed"] += 1

    # Summary
    total_out_mb = totals["chars"] / 1_048_576
    log.info("=" * 56)
    log.info("Conversion complete.")
    log.info("  Converted : %d file(s), %d page(s)", totals["converted"], totals["pages"])
    log.info("  Skipped   : %d (already converted)", totals["skipped"])
    log.info("  No text   : %d (blank/encrypted PDFs)", totals["no_text"])
    log.info("  Failed    : %d", totals["failed"])
    log.info("  Output    : %.2f MB of text", total_out_mb)
    log.info("=" * 56)

    if totals["converted"] > 0:
        log.info("Next step: python3 index_archives.py --root %s", aeria_root)

    if totals["failed"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
