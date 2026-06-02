#!/usr/bin/env python3
# =============================================================================
# Project Aeria — Scout Vision Query Tool
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Sends an image to the local vision model endpoint and returns an
#           analysis grounded in one of several domain-specific modes.
#           All inference is local — no image data leaves this machine.
# Usage:    python3 scout.py IMAGE [--mode MODE] [--query TEXT] [OPTIONS]
# =============================================================================

from __future__ import annotations

import argparse
import base64
import json
import logging
import mimetypes
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Optional: PIL for auto-resizing large images before sending
try:
    from PIL import Image  # type: ignore
    import io
    _HAS_PIL = True
except ImportError:
    _HAS_PIL = False

SUPPORTED_EXTS  = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
MAX_BYTES_WARN  = 2 * 1024 * 1024   # 2 MB — warn above this
MAX_BYTES_HARD  = 10 * 1024 * 1024  # 10 MB — refuse above this
RESIZE_MAX_PX   = 1024              # Max dimension when PIL is available

# ---------------------------------------------------------------------------
# Domain-specific system prompts — each primed for a survival use case
# ---------------------------------------------------------------------------
MODES: dict[str, str] = {

    "general": (
        "Describe this image in precise, factual detail. "
        "Include all visible objects, text, spatial relationships, and notable features."
    ),

    "wound": (
        "[MEDICINE] You are assisting a field medic with no hospital access.\n"
        "Examine this image and report:\n\n"
        "WOUND TYPE:       [laceration / puncture / burn / crush / abrasion / avulsion]\n"
        "LOCATION:         [anatomical location, side of body]\n"
        "ESTIMATED DEPTH:  [superficial / deep / through-and-through]\n"
        "BLEEDING:         [controlled / active arterial / active venous / none visible]\n"
        "CONTAMINATION:    [clean / dirty / embedded debris / foreign body]\n"
        "TISSUE CONDITION: [intact / devitalised / necrotic]\n"
        "IMMEDIATE PRIORITY: [numbered actions in order]\n\n"
        "Do not speculate beyond what is directly visible. "
        "If image quality prevents assessment of any field, say UNABLE TO ASSESS."
    ),

    "plant": (
        "Identify this plant specimen. Report:\n\n"
        "LIKELY SPECIES:    [common name / Latin binomial]\n"
        "CONFIDENCE:        [high / medium / low — be honest]\n"
        "KEY FEATURES:      [leaf shape, margin, arrangement; stem; flowers; fruit; bark]\n"
        "EDIBILITY:         [edible / toxic / unknown]\n"
        "  If edible — which parts, preparation required\n"
        "  If toxic  — toxin type, symptoms of exposure\n"
        "DANGEROUS LOOKALIKES: [species that could be confused with this one]\n"
        "MEDICINAL USE:     [if documented in traditional or clinical literature]\n\n"
        "If confidence is LOW, state that explicitly and do not recommend consumption."
    ),

    "mineral": (
        "Identify this rock or mineral sample. Report:\n\n"
        "LIKELY MATERIAL:  [mineral / rock type]\n"
        "CONFIDENCE:       [high / medium / low]\n"
        "VISIBLE PROPERTIES:\n"
        "  Colour:         [describe fully — streak colour if visible]\n"
        "  Luster:         [metallic / vitreous / resinous / earthy / silky]\n"
        "  Crystal form:   [cubic / hexagonal / massive / amorphous / etc]\n"
        "  Cleavage/fracture: [describe]\n"
        "  Texture:        [coarse / fine / glassy / granular]\n"
        "SUGGESTED FIELD TESTS: [streak, hardness scale estimate, acid test, magnet]\n"
        "PRACTICAL USES:   [construction material / ore / flux / abrasive / none]\n\n"
        "If the sample is unidentifiable from the image alone, state which field "
        "tests would resolve the identification."
    ),

    "map": (
        "Describe this map, diagram, or schematic in full detail.\n\n"
        "TYPE:          [topographic / road / hand-drawn / technical schematic / floor plan / other]\n"
        "ORIENTATION:   [cardinal directions if shown, or unknown]\n"
        "SCALE:         [if visible]\n"
        "KEY FEATURES:  [list all labelled landmarks, roads, structures, boundaries, waterways]\n"
        "LEGEND:        [transcribe any legend or key symbols]\n"
        "TEXT LABELS:   [transcribe all readable text exactly]\n"
        "CONDITION:     [image quality and any illegible areas]\n\n"
        "If this is a technical schematic, identify the system type and list all "
        "visible components, connections, and labels."
    ),

    "mechanical": (
        "[ENGINEERING] Identify this mechanical component or assembly.\n\n"
        "COMPONENT TYPE:  [what it is and its function]\n"
        "MATERIAL:        [steel / cast iron / aluminium / plastic / unknown — visible clues]\n"
        "CONDITION:       [new / worn / damaged — describe specific defects]\n"
        "  Cracks:        [location and severity]\n"
        "  Wear surfaces: [describe]\n"
        "  Corrosion:     [location and type]\n"
        "REPAIR APPROACH: [what needs to be done]\n"
        "TOOLS REQUIRED:  [list]\n"
        "FABRICATION:     [can this be field-fabricated? from what stock?]\n\n"
        "If the component is unidentifiable, describe it in enough detail that "
        "someone could search a parts manual."
    ),

    "document": (
        "Transcribe all text visible in this image as accurately as possible.\n"
        "Preserve headings, numbered lists, table structure, and paragraph breaks.\n"
        "Mark uncertain text with [?]. Mark illegible sections with [ILLEGIBLE].\n"
        "Do not summarise — transcribe verbatim."
    ),
}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(log_dir: Path) -> logging.Logger:
    log_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    fmt     = "[%(asctime)s] [%(levelname)-5s] %(message)s"
    datefmt = "%Y-%m-%dT%H:%M:%SZ"
    logging.basicConfig(
        level=logging.INFO, format=fmt, datefmt=datefmt,
        handlers=[
            logging.FileHandler(log_dir / f"scout_{ts}.log", encoding="utf-8"),
            logging.StreamHandler(sys.stderr),
        ],
    )
    return logging.getLogger("aeria.scout")


# ---------------------------------------------------------------------------
# Image preparation
# ---------------------------------------------------------------------------

def load_image_b64(path: Path, log: logging.Logger) -> tuple[str, str]:
    """
    Load an image file, optionally resize it, and return (mime_type, base64_str).
    Resizes down to RESIZE_MAX_PX on longest side if PIL is available and the
    file exceeds MAX_BYTES_WARN — keeps quality high while reducing token cost.
    """
    size = path.stat().st_size

    if size > MAX_BYTES_HARD:
        log.error("Image too large: %.1f MB (limit %d MB). Resize before sending.",
                  size / 1_048_576, MAX_BYTES_HARD // 1_048_576)
        sys.exit(1)

    # Determine MIME type
    mime, _ = mimetypes.guess_type(str(path))
    if mime not in {"image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp"}:
        mime = "image/jpeg"   # safe fallback

    raw = path.read_bytes()

    if size > MAX_BYTES_WARN and _HAS_PIL:
        log.info("Image is %.1f MB — auto-resizing to %dpx max dimension.",
                 size / 1_048_576, RESIZE_MAX_PX)
        img = Image.open(io.BytesIO(raw))
        img.thumbnail((RESIZE_MAX_PX, RESIZE_MAX_PX), Image.LANCZOS)
        buf = io.BytesIO()
        save_fmt = "JPEG" if mime == "image/jpeg" else "PNG"
        img.save(buf, format=save_fmt, quality=85)
        raw = buf.getvalue()
        log.info("Resized to %d bytes.", len(raw))
    elif size > MAX_BYTES_WARN:
        log.warning("Image is %.1f MB. Install Pillow for auto-resize: pip install Pillow",
                    size / 1_048_576)

    return mime, base64.b64encode(raw).decode("ascii")


# ---------------------------------------------------------------------------
# Vision API call
# ---------------------------------------------------------------------------

def query_vision(
    image_path: Path,
    prompt: str,
    host: str,
    port: int,
    max_tokens: int,
    temperature: float,
    log: logging.Logger,
) -> str:
    """
    Send image + prompt to the llamafile vision endpoint.
    Uses the OpenAI multimodal message format.
    Returns the model's response text.
    """
    mime, b64 = load_image_b64(image_path, log)
    endpoint  = f"http://{host}:{port}/v1/chat/completions"

    payload = json.dumps({
        "model":       "local",
        "max_tokens":  max_tokens,
        "temperature": temperature,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type":      "image_url",
                        "image_url": {"url": f"data:{mime};base64,{b64}"},
                    },
                    {
                        "type": "text",
                        "text": prompt,
                    },
                ],
            }
        ],
    }).encode()

    req = urllib.request.Request(
        endpoint, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read())
    except urllib.error.URLError as exc:
        log.error("Vision endpoint unreachable at %s: %s", endpoint, exc)
        log.error("Start the Scout with: ./04_THE_SCOUT/start_scout.sh")
        sys.exit(1)

    if "error" in data:
        log.error("Model returned error: %s", data["error"])
        sys.exit(1)

    return data["choices"][0]["message"]["content"]


# ---------------------------------------------------------------------------
# Session logging
# ---------------------------------------------------------------------------

def log_session(
    log_dir: Path,
    image_path: Path,
    mode: str,
    prompt: str,
    response: str,
) -> Path:
    log_dir.mkdir(parents=True, exist_ok=True)
    ts       = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    out_path = log_dir / f"scout_{ts}_{mode}.log"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"IMAGE:  {image_path}\n")
        f.write(f"MODE:   {mode}\n")
        f.write(f"TIME:   {datetime.now(timezone.utc).isoformat()}\n\n")
        f.write("PROMPT:\n")
        f.write(prompt + "\n\n")
        f.write("RESPONSE:\n")
        f.write(response + "\n")
    return out_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    mode_list = " | ".join(MODES)
    p = argparse.ArgumentParser(
        prog="scout.py",
        description="Project Aeria — Scout Vision Query Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Modes:
  {mode_list}

Examples:
  python3 scout.py wound.jpg --mode wound
  python3 scout.py plant_photo.jpg --mode plant
  python3 scout.py topo_map.jpg --mode map
  python3 scout.py engine_part.jpg --mode mechanical
  python3 scout.py handwritten_note.jpg --mode document
  python3 scout.py photo.jpg --query "Is there visible structural damage to the beam?"
""",
    )
    p.add_argument("image",
                   help="Path to image file (.jpg, .png, .webp, .bmp)")
    p.add_argument("--mode",       choices=list(MODES), default="general",
                   help=f"Analysis mode (default: general)")
    p.add_argument("--query",      default=None, metavar="TEXT",
                   help="Custom query — overrides the mode prompt")
    p.add_argument("--root",       default=None,
                   help="AERIA_ROOT path (default: two levels above this script)")
    p.add_argument("--host",       default="127.0.0.1",
                   help="Vision model host (default: 127.0.0.1)")
    p.add_argument("--port",       type=int, default=8081,
                   help="Vision model port (default: 8081)")
    p.add_argument("--max-tokens", type=int, default=1024,
                   help="Max response tokens (default: 1024)")
    p.add_argument("--temperature", type=float, default=0.1,
                   help="Sampling temperature — keep low for factual output (default: 0.1)")
    p.add_argument("--no-log",     action="store_true",
                   help="Do not save session log")
    return p


def main() -> None:
    args = build_parser().parse_args()

    script_dir = Path(__file__).resolve().parent
    aeria_root = Path(args.root) if args.root else script_dir.parent
    log_dir    = aeria_root / "05_USER_ADDITIONS" / "logs"

    # Fall back to /tmp if drive is read-only
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        (log_dir / ".w").touch()
        (log_dir / ".w").unlink()
    except OSError:
        log_dir = Path("/tmp/aeria_logs")
        log_dir.mkdir(parents=True, exist_ok=True)

    log = setup_logging(log_dir)

    image_path = Path(args.image)
    if not image_path.is_file():
        log.error("Image not found: %s", image_path)
        sys.exit(1)
    if image_path.suffix.lower() not in SUPPORTED_EXTS:
        log.error("Unsupported image format: %s  (supported: %s)",
                  image_path.suffix, ", ".join(sorted(SUPPORTED_EXTS)))
        sys.exit(1)

    prompt = args.query if args.query else MODES[args.mode]
    mode   = "custom" if args.query else args.mode

    log.info("Image : %s (%.1f KB)", image_path.name, image_path.stat().st_size / 1024)
    log.info("Mode  : %s", mode)
    log.info("Scout : http://%s:%d", args.host, args.port)

    response = query_vision(
        image_path  = image_path,
        prompt      = prompt,
        host        = args.host,
        port        = args.port,
        max_tokens  = args.max_tokens,
        temperature = args.temperature,
        log         = log,
    )

    print(f"\n{'═' * 64}")
    print(f"  SCOUT ANALYSIS  [{mode.upper()}]  {image_path.name}")
    print(f"{'═' * 64}")
    print(response)
    print(f"{'═' * 64}\n")

    if not args.no_log:
        saved = log_session(log_dir, image_path, mode, prompt, response)
        log.info("Session saved: %s", saved)


if __name__ == "__main__":
    main()
