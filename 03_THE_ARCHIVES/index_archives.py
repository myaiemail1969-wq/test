#!/usr/bin/env python3
# =============================================================================
# Project Aeria — Archive Indexer
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Ingests PDFs and plain-text files from 03_THE_ARCHIVES/, splits
#           them into overlapping chunks, and builds a SQLite FTS5 full-text
#           search index for Council agent retrieval. Optionally generates
#           vector embeddings via the local llamafile /v1/embeddings endpoint.
#           All processing is local — no network calls leave this machine.
# Usage:    python3 index_archives.py [OPTIONS]
#           python3 index_archives.py --help
# =============================================================================

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import sqlite3
import struct
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Generator

# ---------------------------------------------------------------------------
# PDF backend — detect what is installed, degrade gracefully
# ---------------------------------------------------------------------------
_PDF_BACKEND: str | None = None

try:
    import pdfplumber  # type: ignore
    _PDF_BACKEND = "pdfplumber"
except ImportError:
    pass

if _PDF_BACKEND is None:
    try:
        import pypdf  # type: ignore  # pypdf >= 3.x (successor to PyPDF2)
        _PDF_BACKEND = "pypdf"
    except ImportError:
        pass

if _PDF_BACKEND is None:
    try:
        import PyPDF2  # type: ignore  # legacy fallback
        _PDF_BACKEND = "PyPDF2"
    except ImportError:
        pass

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CHUNK_CHARS   = 1800   # ~450 tokens at 4 chars/token — safe for Q4/Q5 context windows
CHUNK_OVERLAP = 300    # character overlap between adjacent chunks
SUPPORTED_EXT = {".pdf", ".txt", ".md", ".rst"}
INDEX_DB_NAME = "archive_index.db"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(log_dir: Path, verbose: bool) -> logging.Logger:
    """Configure file + stdout logging. Returns the package logger."""
    log_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    log_path = log_dir / f"indexer_{ts}.log"

    fmt     = "[%(asctime)s] [%(levelname)-5s] %(message)s"
    datefmt = "%Y-%m-%dT%H:%M:%SZ"
    level   = logging.DEBUG if verbose else logging.INFO

    logging.basicConfig(
        level=level, format=fmt, datefmt=datefmt,
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    log = logging.getLogger("aeria.indexer")
    log.info("Log: %s", log_path)
    return log


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def open_db(db_path: Path) -> sqlite3.Connection:
    """Open (or create) the SQLite index database and apply the schema."""
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    _apply_schema(conn)
    return conn


def _apply_schema(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS documents (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path   TEXT    NOT NULL UNIQUE,
            file_hash   TEXT    NOT NULL,
            file_size   INTEGER NOT NULL,
            page_count  INTEGER,
            doc_type    TEXT    NOT NULL,
            indexed_at  TEXT    NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            chunk_index INTEGER NOT NULL,
            page_num    INTEGER,
            char_start  INTEGER NOT NULL,
            char_end    INTEGER NOT NULL,
            content     TEXT    NOT NULL
        );

        -- FTS5 full-text index backed by the chunks table.
        -- content_rowid links FTS rowids to chunks.id.
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            content,
            content='chunks',
            content_rowid='id',
            tokenize='unicode61'
        );

        -- Triggers keep FTS in sync with the chunks table.
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, content)
                VALUES (new.id, new.content);
        END;

        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, content)
                VALUES ('delete', old.id, old.content);
        END;

        CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, content)
                VALUES ('delete', old.id, old.content);
            INSERT INTO chunks_fts(rowid, content)
                VALUES (new.id, new.content);
        END;

        -- Optional embedding storage (BLOB of packed float32 LE).
        CREATE TABLE IF NOT EXISTS embeddings (
            chunk_id   INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
            model_name TEXT    NOT NULL,
            dimensions INTEGER NOT NULL,
            vector     BLOB    NOT NULL
        );
    """)
    conn.commit()


# ---------------------------------------------------------------------------
# File hashing (for resume / change-detection)
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    """Return hex-encoded SHA-256 of a file's contents."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------

def extract_pdf(path: Path, log: logging.Logger) -> list[tuple[int, str]]:
    """
    Extract text from a PDF file.
    Returns list of (page_number_1indexed, text) for non-empty pages.
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


def extract_text(path: Path, log: logging.Logger) -> list[tuple[int, str]]:
    """Read a plain-text/markdown file. Returns [(1, full_content)]."""
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
        return [(1, content)] if content.strip() else []
    except Exception as exc:
        log.error("Cannot read '%s': %s", path.name, exc)
        return []


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

def chunk_page(
    text: str,
    chunk_size: int,
    overlap: int,
) -> Generator[tuple[int, int, str], None, None]:
    """
    Yield (char_start, char_end, chunk_text) from a single page of text.
    Prefers sentence boundaries ('. ') to avoid cutting mid-sentence.
    """
    start  = 0
    length = len(text)
    while start < length:
        end = min(start + chunk_size, length)
        # Snap to a sentence boundary if we are not at the end of the string
        if end < length:
            boundary = text.rfind(". ", start, end)
            if boundary > start + overlap:
                end = boundary + 2      # keep the period and space
        chunk = text[start:end].strip()
        if chunk:
            yield start, end, chunk
        if end >= length:
            break
        start = end - overlap


# ---------------------------------------------------------------------------
# Embeddings via llamafile /v1/embeddings (stdlib only — no requests lib)
# ---------------------------------------------------------------------------

def embed_batch(
    texts: list[str],
    host: str,
    port: int,
    model: str,
    log: logging.Logger,
) -> list[list[float]] | None:
    """
    POST a batch of texts to the local llamafile embedding endpoint.
    Returns a list of float vectors, or None on any failure.
    Uses stdlib urllib — no external dependencies.
    """
    url     = f"http://{host}:{port}/v1/embeddings"
    payload = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        return [item["embedding"] for item in data["data"]]
    except urllib.error.URLError as exc:
        log.error("Embedding request to %s failed: %s", url, exc)
        return None
    except (KeyError, json.JSONDecodeError) as exc:
        log.error("Unexpected response from embedding endpoint: %s", exc)
        return None


def pack_vector(vector: list[float]) -> bytes:
    """Pack a float32 vector as little-endian bytes for BLOB storage."""
    return struct.pack(f"<{len(vector)}f", *vector)


def unpack_vector(blob: bytes) -> list[float]:
    """Unpack a BLOB back to a Python float list."""
    return list(struct.unpack(f"<{len(blob) // 4}f", blob))


# ---------------------------------------------------------------------------
# Cosine similarity (pure Python — no numpy required)
# ---------------------------------------------------------------------------

def cosine_sim(a: list[float], b: list[float]) -> float:
    """Return cosine similarity in [–1, 1] between two equal-length vectors."""
    dot   = sum(x * y for x, y in zip(a, b))
    mag_a = sum(x * x for x in a) ** 0.5
    mag_b = sum(x * x for x in b) ** 0.5
    if mag_a == 0.0 or mag_b == 0.0:
        return 0.0
    return dot / (mag_a * mag_b)


# ---------------------------------------------------------------------------
# Indexing
# ---------------------------------------------------------------------------

def is_indexed(conn: sqlite3.Connection, rel_path: str, file_hash: str) -> bool:
    """True if the file is already in the index with the same content hash."""
    row = conn.execute(
        "SELECT file_hash FROM documents WHERE file_path = ?", (rel_path,)
    ).fetchone()
    return row is not None and row[0] == file_hash


def remove_document(conn: sqlite3.Connection, rel_path: str) -> None:
    """Delete a stale document and cascade-remove its chunks and embeddings."""
    conn.execute("DELETE FROM documents WHERE file_path = ?", (rel_path,))
    conn.commit()


def index_file(
    path: Path,
    archives_root: Path,
    conn: sqlite3.Connection,
    log: logging.Logger,
    embed_cfg: dict | None,
    chunk_size: int,
    overlap: int,
    batch_size: int,
) -> bool:
    """
    Index a single file. Returns True if the file was (re-)indexed,
    False if it was skipped (unchanged) or failed.
    embed_cfg: dict with keys host, port, model — or None to skip embeddings.
    """
    rel_path  = str(path.relative_to(archives_root))
    file_hash = sha256_file(path)

    if is_indexed(conn, rel_path, file_hash):
        log.debug("  SKIP (unchanged): %s", rel_path)
        return False

    # Stale entry — remove before re-indexing
    if conn.execute(
        "SELECT 1 FROM documents WHERE file_path = ?", (rel_path,)
    ).fetchone():
        log.info("  UPDATE: %s", rel_path)
        remove_document(conn, rel_path)
    else:
        log.info("  INDEX:  %s", rel_path)

    # Extract text
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        if _PDF_BACKEND is None:
            log.error("  No PDF library — cannot index %s. Install pdfplumber or pypdf.", path.name)
            return False
        pages    = extract_pdf(path, log)
        doc_type = "pdf"
    else:
        pages    = extract_text(path, log)
        doc_type = "text"

    if not pages:
        log.warning("  No extractable text in %s — skipping.", path.name)
        return False

    page_count = max(p for p, _ in pages)
    now        = datetime.now(timezone.utc).isoformat()

    cur = conn.execute(
        "INSERT INTO documents (file_path, file_hash, file_size, page_count, doc_type, indexed_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (rel_path, file_hash, path.stat().st_size, page_count, doc_type, now),
    )
    doc_id = cur.lastrowid

    # Build and insert chunks
    chunk_rows: list[tuple] = []   # (chunk_index, page_num, char_start, char_end, content)
    for page_num, page_text in pages:
        for cs, ce, ct in chunk_page(page_text, chunk_size, overlap):
            chunk_rows.append((len(chunk_rows), page_num, cs, ce, ct))

    chunk_ids: list[int] = []
    for ci, pn, cs, ce, ct in chunk_rows:
        cur = conn.execute(
            "INSERT INTO chunks (doc_id, chunk_index, page_num, char_start, char_end, content) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (doc_id, ci, pn, cs, ce, ct),
        )
        chunk_ids.append(cur.lastrowid)

    # Optional: generate and store embeddings in configurable batches
    if embed_cfg:
        texts = [row[4] for row in chunk_rows]
        for i in range(0, len(texts), batch_size):
            batch_texts = texts[i : i + batch_size]
            batch_ids   = chunk_ids[i : i + batch_size]
            vectors = embed_batch(
                batch_texts,
                embed_cfg["host"],
                embed_cfg["port"],
                embed_cfg["model"],
                log,
            )
            if vectors is None:
                log.warning("  Embedding failed at batch %d — continuing without vectors.", i)
                break
            for chunk_id, vec in zip(batch_ids, vectors):
                conn.execute(
                    "INSERT INTO embeddings (chunk_id, model_name, dimensions, vector) "
                    "VALUES (?, ?, ?, ?)",
                    (chunk_id, embed_cfg["model"], len(vec), pack_vector(vec)),
                )

    conn.commit()
    log.info("  %d chunks stored from %s", len(chunk_rows), rel_path)
    return True


# ---------------------------------------------------------------------------
# Retrieval
# ---------------------------------------------------------------------------

def search_fts(conn: sqlite3.Connection, query: str, top_k: int) -> list[dict]:
    """
    Full-text search using SQLite FTS5 BM25 ranking.
    BM25 scores from FTS5 are negative; ORDER BY ASC returns best matches first.
    """
    rows = conn.execute(
        """
        SELECT c.id, d.file_path, c.page_num, c.content, bm25(chunks_fts) AS score
        FROM   chunks_fts
        JOIN   chunks    c ON c.id  = chunks_fts.rowid
        JOIN   documents d ON d.id  = c.doc_id
        WHERE  chunks_fts MATCH ?
        ORDER  BY score ASC
        LIMIT  ?
        """,
        (query, top_k),
    ).fetchall()
    return [
        {"chunk_id": r[0], "source": r[1], "page": r[2],
         "content": r[3], "score": r[4]}
        for r in rows
    ]


def search_semantic(
    conn: sqlite3.Connection,
    query: str,
    embed_cfg: dict,
    top_k: int,
    log: logging.Logger,
) -> list[dict]:
    """
    Semantic search: embed the query, compute cosine similarity against all
    stored chunk embeddings, return top-k results sorted by similarity.
    """
    vecs = embed_batch([query], embed_cfg["host"], embed_cfg["port"],
                       embed_cfg["model"], log)
    if not vecs:
        log.error("Could not embed query — falling back to FTS only.")
        return []

    query_vec = vecs[0]
    rows = conn.execute(
        "SELECT e.chunk_id, e.vector, c.content, d.file_path, c.page_num "
        "FROM embeddings e "
        "JOIN chunks    c ON c.id = e.chunk_id "
        "JOIN documents d ON d.id = c.doc_id"
    ).fetchall()

    scored = [
        {
            "chunk_id": r[0],
            "content":  r[2],
            "source":   r[3],
            "page":     r[4],
            "score":    cosine_sim(query_vec, unpack_vector(r[1])),
        }
        for r in rows
    ]
    scored.sort(key=lambda x: x["score"], reverse=True)
    return scored[:top_k]


def run_query(conn: sqlite3.Connection, args: argparse.Namespace,
              log: logging.Logger) -> None:
    """Execute a retrieval query and print formatted results."""
    embed_cfg = {
        "host": args.embed_host, "port": args.embed_port, "model": args.embed_model
    } if args.embed else None

    results = search_fts(conn, args.query, args.top_k)

    if embed_cfg:
        semantic = search_semantic(conn, args.query, embed_cfg, args.top_k, log)
        # Merge: semantic results first, then any FTS results not already present
        seen = {r["chunk_id"] for r in semantic}
        combined = semantic + [r for r in results if r["chunk_id"] not in seen]
        results = combined[:args.top_k]

    if not results:
        print("\nNo results found.\n")
        return

    print(f"\n{'═' * 64}")
    print(f"  QUERY: {args.query}")
    print(f"{'═' * 64}")
    for i, r in enumerate(results, 1):
        page_label = f"p.{r['page']}" if r["page"] else "—"
        snippet    = r["content"][:320].replace("\n", " ")
        print(f"\n[{i}] {r['source']}  ({page_label})  score={r['score']:.4f}")
        print(f"    {snippet}…")
    print(f"\n{'═' * 64}\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="index_archives.py",
        description="Project Aeria — Archive Indexer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Index all archives (FTS keyword search only):
    python3 index_archives.py --root /mnt/aeria

  Index with vector embeddings (llamafile must be running):
    python3 index_archives.py --root /mnt/aeria --embed --batch-size 4

  Query the FTS index:
    python3 index_archives.py --root /mnt/aeria --query "tourniquet arterial bleed"

  Query with semantic re-ranking (llamafile must be running):
    python3 index_archives.py --root /mnt/aeria --query "forge weld temperature" --embed

PDF library installation (choose one):
    pip install pdfplumber     # recommended — best table extraction
    pip install pypdf          # lightweight alternative
""",
    )
    p.add_argument("--root",
                   help="AERIA_ROOT path (default: two levels above this script)")
    p.add_argument("--chunk-size", type=int, default=CHUNK_CHARS, metavar="N",
                   help=f"Characters per chunk (default: {CHUNK_CHARS})")
    p.add_argument("--overlap", type=int, default=CHUNK_OVERLAP, metavar="N",
                   help=f"Overlap between chunks in chars (default: {CHUNK_OVERLAP})")
    p.add_argument("--embed", action="store_true",
                   help="Generate vector embeddings via local llamafile endpoint")
    p.add_argument("--embed-host", default="127.0.0.1",
                   help="llamafile host for /v1/embeddings (default: 127.0.0.1)")
    p.add_argument("--embed-port", type=int, default=8080,
                   help="llamafile port for /v1/embeddings (default: 8080)")
    p.add_argument("--embed-model", default="local",
                   help="Model name to pass to /v1/embeddings (default: local)")
    p.add_argument("--batch-size", type=int, default=8, metavar="N",
                   help="Chunks per embedding batch — lower value uses less VRAM (default: 8)")
    p.add_argument("--query", metavar="TEXT",
                   help="Search query — runs retrieval mode instead of indexing")
    p.add_argument("--top-k", type=int, default=5, metavar="N",
                   help="Number of results to return for --query (default: 5)")
    p.add_argument("--verbose", action="store_true",
                   help="Enable DEBUG-level logging")
    return p


def main() -> None:
    args = build_parser().parse_args()

    script_dir   = Path(__file__).resolve().parent
    aeria_root   = Path(args.root) if args.root else script_dir.parent
    archives_dir = aeria_root / "03_THE_ARCHIVES"
    log_dir      = aeria_root / "05_USER_ADDITIONS" / "logs"
    db_path      = archives_dir / INDEX_DB_NAME

    log = setup_logging(log_dir, args.verbose)
    log.info("AERIA_ROOT   : %s", aeria_root)
    log.info("Archives dir : %s", archives_dir)
    log.info("Index DB     : %s", db_path)
    log.info("PDF backend  : %s", _PDF_BACKEND or "NONE — install pdfplumber or pypdf")

    if not archives_dir.is_dir():
        log.error("Archives directory not found: %s", archives_dir)
        sys.exit(1)

    conn = open_db(db_path)

    # ── Query mode ──────────────────────────────────────────────────────────
    if args.query:
        run_query(conn, args, log)
        conn.close()
        return

    # ── Index mode ──────────────────────────────────────────────────────────
    embed_cfg: dict | None = None
    if args.embed:
        embed_cfg = {
            "host":  args.embed_host,
            "port":  args.embed_port,
            "model": args.embed_model,
        }
        log.info("Embeddings   : http://%s:%d  batch=%d",
                 args.embed_host, args.embed_port, args.batch_size)
    else:
        log.info("Embeddings   : disabled (FTS only)")

    source_files = sorted(
        p for p in archives_dir.rglob("*")
        if p.is_file()
        and p.suffix.lower() in SUPPORTED_EXT
        and p.name != INDEX_DB_NAME
    )

    if not source_files:
        log.warning("No supported files found in %s", archives_dir)
        log.warning("Supported extensions: %s", ", ".join(sorted(SUPPORTED_EXT)))
        conn.close()
        sys.exit(0)

    log.info("Files found  : %d", len(source_files))

    indexed = skipped = failed = 0
    for path in source_files:
        try:
            ok = index_file(
                path=path,
                archives_root=archives_dir,
                conn=conn,
                log=log,
                embed_cfg=embed_cfg,
                chunk_size=args.chunk_size,
                overlap=args.overlap,
                batch_size=args.batch_size,
            )
            if ok:
                indexed += 1
            else:
                skipped += 1
        except Exception as exc:
            log.error("FAILED: %s — %s", path.name, exc, exc_info=args.verbose)
            conn.rollback()
            failed += 1

    # Final stats
    total_docs   = conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
    total_chunks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    total_embed  = conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    db_mb        = db_path.stat().st_size / 1_048_576

    log.info("=" * 56)
    log.info("Indexing complete.")
    log.info("  Indexed  : %d file(s)", indexed)
    log.info("  Skipped  : %d file(s) (unchanged)", skipped)
    log.info("  Failed   : %d file(s)", failed)
    log.info("  Docs     : %d total in index", total_docs)
    log.info("  Chunks   : %d total", total_chunks)
    log.info("  Embeddings: %d", total_embed)
    log.info("  DB size  : %.1f MB", db_mb)
    log.info("=" * 56)

    conn.close()
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
