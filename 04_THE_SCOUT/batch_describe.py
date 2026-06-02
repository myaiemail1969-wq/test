#!/usr/bin/env python3
# =============================================================================
# Project Aeria — Scout Batch Image Describer
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Processes a directory of images through the vision model and
#           writes a .txt description alongside each image. This makes
#           photographs, maps, diagrams, and scanned documents discoverable
#           by the FTS5 archive indexer (index_archives.py).
#           Run this, then re-run index_archives.py to make images searchable.
# Usage:    python3 batch_describe.py --input-dir DIR [OPTIONS]
# =============================================================================

from __future__ import annotations

import argparse
import base64
import json
import logging
import mimetypes
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

IMAGE_EXTS     = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
MAX_BYTES_HARD = 10 * 1024 * 1024
# Pause between requests so the vision model doesn't queue-starve
REQUEST_DELAY  = 0.5   # seconds

DESCRIBE_PROMPT = (
    "Describe this image in precise, factual detail for a technical archive. "
    "Include: all visible objects and their condition, any text or labels "
    "(transcribe verbatim), spatial relationships, scale indicators, "
    "and the likely purpose or context of the image. "
    "Be specific — this description must allow someone to find this image "
    "by searching for its contents."
)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(log_dir: Path, verbose: bool) -> logging.Logger:
    log_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    fmt     = "[%(asctime)s] [%(levelname)-5s] %(message)s"
    datefmt = "%Y-%m-%dT%H:%M:%SZ"
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format=fmt, datefmt=datefmt,
        handlers=[
            logging.FileHandler(log_dir / f"batch_describe_{ts}.log", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    log = logging.getLogger("aeria.batch_describe")
    log.info("Log: %s", log_dir / f"batch_describe_{ts}.log")
    return log


# ---------------------------------------------------------------------------
# Image encoding
# ---------------------------------------------------------------------------

def encode_image(path: Path) -> tuple[str, str] | None:
    """
    Return (mime_type, base64_string) for an image file.
    Returns None if the file is too large or unreadable.
    """
    size = path.stat().st_size
    if size > MAX_BYTES_HARD:
        return None
    mime, _ = mimetypes.guess_type(str(path))
    if mime not in {"image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp"}:
        mime = "image/jpeg"
    raw = path.read_bytes()
    return mime, base64.b64encode(raw).decode("ascii")


# ---------------------------------------------------------------------------
# Vision API call
# ---------------------------------------------------------------------------

def describe_image(
    image_path: Path,
    host: str,
    port: int,
    max_tokens: int,
    log: logging.Logger,
) -> str | None:
    """
    Call the vision endpoint and return the description string, or None on error.
    """
    encoded = encode_image(image_path)
    if encoded is None:
        log.warning("  SKIP (too large): %s", image_path.name)
        return None
    mime, b64 = encoded

    payload = json.dumps({
        "model":      "local",
        "max_tokens": max_tokens,
        "temperature": 0.1,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url",
                     "image_url": {"url": f"data:{mime};base64,{b64}"}},
                    {"type": "text", "text": DESCRIBE_PROMPT},
                ],
            }
        ],
    }).encode()

    req = urllib.request.Request(
        f"http://{host}:{port}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"]
    except urllib.error.URLError as exc:
        log.error("  Scout endpoint unreachable: %s", exc)
        return None
    except (KeyError, json.JSONDecodeError) as exc:
        log.error("  Unexpected response: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Output path
# ---------------------------------------------------------------------------

def desc_path_for(image_path: Path, output_dir: Path | None) -> Path:
    """
    Return the .txt output path for an image.
    Places it alongside the image if output_dir is None,
    otherwise mirrors the directory structure under output_dir.
    """
    stem = image_path.stem + "_scout_desc"
    if output_dir is None:
        return image_path.parent / f"{stem}.txt"
    return output_dir / f"{stem}.txt"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="batch_describe.py",
        description="Project Aeria — Scout Batch Image Describer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Describe all images in a directory:
    python3 batch_describe.py --input-dir /mnt/aeria/03_THE_ARCHIVES/maps

  Write descriptions to a separate folder:
    python3 batch_describe.py --input-dir ./images --output-dir ./descriptions

  Dry run — show what would be processed:
    python3 batch_describe.py --input-dir ./images --dry-run

After running, re-index the archives to make images text-searchable:
    python3 03_THE_ARCHIVES/index_archives.py --root /mnt/aeria
""",
    )
    p.add_argument("--input-dir",  required=True, metavar="DIR",
                   help="Directory containing images to describe")
    p.add_argument("--output-dir", default=None, metavar="DIR",
                   help="Where to write .txt files (default: alongside each image)")
    p.add_argument("--root",       default=None,
                   help="AERIA_ROOT for log path (default: two levels above this script)")
    p.add_argument("--host",       default="127.0.0.1",
                   help="Vision model host (default: 127.0.0.1)")
    p.add_argument("--port",       type=int, default=8081,
                   help="Vision model port (default: 8081)")
    p.add_argument("--max-tokens", type=int, default=512,
                   help="Max tokens per description (default: 512)")
    p.add_argument("--overwrite",  action="store_true",
                   help="Re-describe images that already have a .txt output")
    p.add_argument("--dry-run",    action="store_true",
                   help="Show what would be processed without calling the model")
    p.add_argument("--verbose",    action="store_true",
                   help="Enable DEBUG logging")
    return p


def main() -> None:
    args = build_parser().parse_args()

    script_dir = Path(__file__).resolve().parent
    aeria_root = Path(args.root) if args.root else script_dir.parent
    log_dir    = aeria_root / "05_USER_ADDITIONS" / "logs"
    input_dir  = Path(args.input_dir)
    output_dir = Path(args.output_dir) if args.output_dir else None

    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        log_dir = Path("/tmp/aeria_logs")
        log_dir.mkdir(parents=True, exist_ok=True)

    log = setup_logging(log_dir, args.verbose)
    log.info("Input dir  : %s", input_dir)
    log.info("Output dir : %s", output_dir or "(alongside source)")
    log.info("Scout      : http://%s:%d", args.host, args.port)

    if not input_dir.is_dir():
        log.error("Input directory not found: %s", input_dir)
        sys.exit(1)

    images = sorted(
        p for p in input_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    )

    if not images:
        log.warning("No image files found in %s", input_dir)
        log.warning("Supported: %s", ", ".join(sorted(IMAGE_EXTS)))
        sys.exit(0)

    log.info("Images found: %d", len(images))

    if args.dry_run:
        log.info("DRY RUN — no files will be written and no model calls made.")
        for img in images:
            dest   = desc_path_for(img, output_dir)
            status = "SKIP" if dest.exists() and not args.overwrite else "DESCRIBE"
            size   = img.stat().st_size / 1024
            print(f"  [{status:8s}] {img.name}  ({size:.0f} KB) → {dest.name}")
        return

    totals = {"described": 0, "skipped": 0, "failed": 0}

    for i, image_path in enumerate(images, 1):
        dest = desc_path_for(image_path, output_dir)

        if dest.exists() and not args.overwrite:
            log.debug("  SKIP (exists): %s", image_path.name)
            totals["skipped"] += 1
            continue

        log.info("[%d/%d] %s", i, len(images), image_path.name)
        description = describe_image(image_path, args.host, args.port,
                                     args.max_tokens, log)

        if description is None:
            totals["failed"] += 1
            continue

        if output_dir:
            output_dir.mkdir(parents=True, exist_ok=True)

        # Write description with source header so the indexer gets full context
        dest.write_text(
            f"Image: {image_path.name}\n"
            f"Described: {datetime.now(timezone.utc).isoformat()}\n\n"
            f"{description}\n",
            encoding="utf-8",
        )
        log.info("  → %s (%d chars)", dest.name, len(description))
        totals["described"] += 1

        if i < len(images):
            time.sleep(REQUEST_DELAY)

    log.info("=" * 56)
    log.info("Batch complete.")
    log.info("  Described : %d", totals["described"])
    log.info("  Skipped   : %d (already done)", totals["skipped"])
    log.info("  Failed    : %d", totals["failed"])
    log.info("=" * 56)

    if totals["described"] > 0:
        log.info("Next: python3 03_THE_ARCHIVES/index_archives.py --root %s", aeria_root)

    if totals["failed"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
