#!/usr/bin/env python3
# =============================================================================
# Project Aeria — RAG Query Bridge
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Queries the SQLite FTS5 archive index built by index_archives.py
#           and returns relevant document chunks for injection into a Council
#           agent system prompt. Designed to be called by council_invoke.sh.
#           All operations are local — no network calls.
# Usage:    python3 rag_query.py --query TEXT [OPTIONS]
# =============================================================================

from __future__ import annotations

import argparse
import json
import sqlite3
import struct
import sys
import urllib.error
import urllib.request
from pathlib import Path

INDEX_DB_NAME = "archive_index.db"
# Characters to show per chunk in prompt format — keeps context within token budget
PROMPT_SNIPPET_CHARS = 1400


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def open_db(db_path: Path) -> sqlite3.Connection:
    """Open the index DB read-only. Exits with a clear message if missing."""
    if not db_path.exists():
        print(
            f"[RAG] Index not found: {db_path}\n"
            f"      Run index_archives.py --root <AERIA_ROOT> to build it.",
            file=sys.stderr,
        )
        sys.exit(1)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


# ---------------------------------------------------------------------------
# FTS search
# ---------------------------------------------------------------------------

def search_fts(conn: sqlite3.Connection, query: str, top_k: int) -> list[dict]:
    """
    BM25-ranked full-text search via FTS5.
    FTS5 BM25 scores are negative; ORDER BY ASC returns best matches first.
    """
    try:
        rows = conn.execute(
            """
            SELECT c.id, d.file_path, c.page_num, c.content,
                   bm25(chunks_fts) AS score
            FROM   chunks_fts
            JOIN   chunks    c ON c.id  = chunks_fts.rowid
            JOIN   documents d ON d.id  = c.doc_id
            WHERE  chunks_fts MATCH ?
            ORDER  BY score ASC
            LIMIT  ?
            """,
            (query, top_k),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        print(f"[RAG] FTS query failed: {exc}", file=sys.stderr)
        return []
    return [
        {"chunk_id": r[0], "source": r[1], "page": r[2],
         "content": r[3], "score": float(r[4])}
        for r in rows
    ]


# ---------------------------------------------------------------------------
# Semantic search (optional — requires embeddings in the index)
# ---------------------------------------------------------------------------

def _cosine(a: list[float], b: list[float]) -> float:
    dot   = sum(x * y for x, y in zip(a, b))
    mag_a = sum(x * x for x in a) ** 0.5
    mag_b = sum(x * x for x in b) ** 0.5
    return 0.0 if (mag_a == 0 or mag_b == 0) else dot / (mag_a * mag_b)


def _embed(texts: list[str], host: str, port: int, model: str) -> list[list[float]] | None:
    url     = f"http://{host}:{port}/v1/embeddings"
    payload = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        return [item["embedding"] for item in data["data"]]
    except Exception:
        return None


def search_semantic(
    conn: sqlite3.Connection,
    query: str,
    top_k: int,
    host: str,
    port: int,
    model: str,
) -> list[dict]:
    """Embed the query and rank stored embeddings by cosine similarity."""
    row_count = conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    if row_count == 0:
        return []

    vecs = _embed([query], host, port, model)
    if not vecs:
        return []
    qvec = vecs[0]

    rows = conn.execute(
        "SELECT e.chunk_id, e.vector, c.content, d.file_path, c.page_num "
        "FROM embeddings e "
        "JOIN chunks    c ON c.id = e.chunk_id "
        "JOIN documents d ON d.id = c.doc_id"
    ).fetchall()

    n = len(rows[0][1]) // 4 if rows else 0
    scored = [
        {
            "chunk_id": r[0],
            "content":  r[2],
            "source":   r[3],
            "page":     r[4],
            "score":    _cosine(qvec, list(struct.unpack(f"<{n}f", r[1]))),
        }
        for r in rows
    ]
    scored.sort(key=lambda x: x["score"], reverse=True)
    return scored[:top_k]


# ---------------------------------------------------------------------------
# Result merging
# ---------------------------------------------------------------------------

def merge_results(
    fts_results: list[dict],
    sem_results: list[dict],
    top_k: int,
) -> list[dict]:
    """
    Merge FTS and semantic results, deduplicate by chunk_id.
    Semantic results take priority (higher precision); FTS fills remaining slots.
    """
    seen: set[int] = set()
    merged: list[dict] = []
    for r in sem_results:
        if r["chunk_id"] not in seen:
            merged.append(r)
            seen.add(r["chunk_id"])
    for r in fts_results:
        if r["chunk_id"] not in seen:
            merged.append(r)
            seen.add(r["chunk_id"])
    return merged[:top_k]


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

def fmt_json(results: list[dict]) -> str:
    return json.dumps(results, indent=2)


def fmt_text(results: list[dict]) -> str:
    if not results:
        return "(no results)"
    lines = []
    for i, r in enumerate(results, 1):
        page_label = f"p.{r['page']}" if r["page"] else "—"
        lines.append(f"[{i}] {r['source']}  ({page_label})  score={r['score']:.4f}")
        lines.append(f"    {r['content'][:300].replace(chr(10), ' ')}…")
        lines.append("")
    return "\n".join(lines)


def fmt_prompt(results: list[dict]) -> str:
    """
    Format retrieved chunks as a context block for injection into a
    system prompt. Instructs the model to ground its answer in the context.
    """
    if not results:
        return ""

    lines = [
        "=== RETRIEVED CONTEXT FROM ARCHIVES ===",
        "The following passages were retrieved from the technical library.",
        "Ground your answer in this context. If the context is insufficient,",
        "state that explicitly rather than speculating.",
        "",
    ]
    for i, r in enumerate(results, 1):
        page_label = f"page {r['page']}" if r["page"] else "unknown page"
        source     = Path(r["source"]).name
        snippet    = r["content"][:PROMPT_SNIPPET_CHARS].strip()
        lines += [
            f"[{i}] {source} — {page_label}",
            "─" * 56,
            snippet,
            "",
        ]
    lines.append("=== END ARCHIVE CONTEXT ===")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rag_query.py",
        description="Project Aeria — RAG Query Bridge",
    )
    p.add_argument("--query",  required=True, metavar="TEXT",
                   help="Search query text")
    p.add_argument("--root",   default=None,
                   help="AERIA_ROOT path (default: two levels above this script)")
    p.add_argument("--top-k",  type=int, default=3, metavar="N",
                   help="Number of chunks to retrieve (default: 3)")
    p.add_argument("--format", choices=["json", "text", "prompt"], default="prompt",
                   help="Output format (default: prompt)")
    p.add_argument("--embed",  action="store_true",
                   help="Also run semantic search if embeddings exist in the index")
    p.add_argument("--embed-host",  default="127.0.0.1")
    p.add_argument("--embed-port",  type=int, default=8080)
    p.add_argument("--embed-model", default="local")
    return p


def main() -> None:
    args = build_parser().parse_args()

    script_dir   = Path(__file__).resolve().parent
    aeria_root   = Path(args.root) if args.root else script_dir.parent
    db_path      = aeria_root / "03_THE_ARCHIVES" / INDEX_DB_NAME

    conn = open_db(db_path)

    fts_results = search_fts(conn, args.query, args.top_k)

    sem_results: list[dict] = []
    if args.embed:
        sem_results = search_semantic(
            conn, args.query, args.top_k,
            args.embed_host, args.embed_port, args.embed_model,
        )

    results = merge_results(fts_results, sem_results, args.top_k)
    conn.close()

    if args.format == "json":
        print(fmt_json(results))
    elif args.format == "text":
        print(fmt_text(results))
    else:
        output = fmt_prompt(results)
        if output:
            print(output)
        # Empty output (no results) prints nothing — council_invoke.sh treats
        # empty stdout as "no context available" and proceeds without RAG.


if __name__ == "__main__":
    main()
