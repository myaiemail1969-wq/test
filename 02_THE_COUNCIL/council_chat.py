#!/usr/bin/env python3
# =============================================================================
# Project Aeria — Council Interactive Chat
# Author:   Project Aeria
# Version:  1.0.0
# Modified: YYYY-MM-DD
# Purpose:  Multi-turn conversational interface to a Council agent. Maintains
#           full conversation history, injects fresh RAG context on each turn,
#           and saves the complete session transcript on exit.
#           All inference is local — no data leaves this machine.
# Usage:    python3 council_chat.py --agent surgeon
# =============================================================================

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Terminal colour helpers — degrade gracefully when not in a real terminal
# ---------------------------------------------------------------------------
_IS_TTY = sys.stdout.isatty()

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _IS_TTY else text

def green(t: str)  -> str: return _c("0;32", t)
def yellow(t: str) -> str: return _c("1;33", t)
def cyan(t: str)   -> str: return _c("0;36", t)
def bold(t: str)   -> str: return _c("1",    t)
def dim(t: str)    -> str: return _c("2",    t)
def red(t: str)    -> str: return _c("0;31", t)

# ---------------------------------------------------------------------------
# Agent name → prompt file map
# ---------------------------------------------------------------------------
AGENTS = {
    "surgeon":    "surgeon.prompt.txt",
    "blacksmith": "blacksmith.prompt.txt",
    "engineer":   "engineer.prompt.txt",
    "builder":    "engineer.prompt.txt",
}

COMMANDS = """
  /help          Show this help
  /agent NAME    Switch to a different Council agent mid-session
  /clear         Clear conversation history (keep persona, start fresh)
  /rag on|off    Toggle archive context retrieval
  /context       Show current conversation length (tokens approx)
  /save          Save transcript now without exiting
  /bye  /quit    End session and save transcript
"""


# ---------------------------------------------------------------------------
# RAG retrieval via rag_query.py subprocess
# ---------------------------------------------------------------------------

def get_rag_context(
    query: str,
    aeria_root: Path,
    top_k: int = 3,
) -> str:
    """
    Call rag_query.py as a subprocess and return the formatted context block.
    Returns empty string if no context found or on any failure.
    """
    rag_script = aeria_root / "02_THE_COUNCIL" / "rag_query.py"
    db_path    = aeria_root / "03_THE_ARCHIVES" / "archive_index.db"

    if not rag_script.exists() or not db_path.exists():
        return ""

    try:
        result = subprocess.run(
            [sys.executable, str(rag_script),
             "--root", str(aeria_root),
             "--query", query,
             "--top-k", str(top_k),
             "--format", "prompt"],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout.strip()
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# llamafile chat API call
# ---------------------------------------------------------------------------

def chat(
    messages: list[dict],
    host: str,
    port: int,
    max_tokens: int,
    temperature: float,
) -> str:
    """
    Send the full message history to /v1/chat/completions.
    Returns the assistant's reply text, or raises on failure.
    """
    payload = json.dumps({
        "model":       "local",
        "temperature": temperature,
        "max_tokens":  max_tokens,
        "messages":    messages,
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
    except urllib.error.URLError as exc:
        raise ConnectionError(
            f"Cannot reach llamafile at http://{host}:{port} — "
            f"run startup.sh first.\n  ({exc})"
        ) from exc

    if "error" in data:
        raise RuntimeError(f"Model error: {data['error']}")

    return data["choices"][0]["message"]["content"]


# ---------------------------------------------------------------------------
# Session transcript
# ---------------------------------------------------------------------------

def save_transcript(
    log_dir: Path,
    agent: str,
    turns: list[dict],
) -> Path:
    """Write a human-readable transcript to the log directory."""
    log_dir.mkdir(parents=True, exist_ok=True)
    ts   = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    path = log_dir / f"chat_{ts}_{agent}.log"
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"AGENT:   @{agent.title()}\n")
        f.write(f"STARTED: {datetime.now(timezone.utc).isoformat()}\n")
        f.write("=" * 64 + "\n\n")
        for turn in turns:
            role = turn["role"].upper()
            content = turn["content"]
            # Don't dump the full system prompt — just a marker
            if role == "SYSTEM":
                f.write(f"[SYSTEM PROMPT — {len(content)} chars]\n\n")
            else:
                f.write(f"{role}:\n{content}\n\n{'─' * 40}\n\n")
    return path


# ---------------------------------------------------------------------------
# Main chat loop
# ---------------------------------------------------------------------------

def run_chat(args: "argparse.Namespace") -> None:
    import argparse  # import here to keep top-level clean

    script_dir = Path(__file__).resolve().parent
    aeria_root = Path(args.root) if args.root else script_dir.parent
    council_dir = aeria_root / "02_THE_COUNCIL"
    log_dir     = aeria_root / "05_USER_ADDITIONS" / "logs"

    # Fall back to /tmp if drive is read-only
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        log_dir = Path("/tmp/aeria_logs")
        log_dir.mkdir(parents=True, exist_ok=True)

    # Load initial persona
    current_agent = args.agent.lower()
    if current_agent not in AGENTS:
        print(red(f"Unknown agent '{current_agent}'. Choose: {', '.join(AGENTS)}"))
        sys.exit(1)

    def load_persona(agent: str) -> str:
        prompt_file = council_dir / AGENTS[agent]
        if not prompt_file.exists():
            print(red(f"Persona file not found: {prompt_file}"))
            sys.exit(1)
        return prompt_file.read_text(encoding="utf-8")

    persona = load_persona(current_agent)
    use_rag = not args.no_rag

    # messages holds the full conversation history sent to the API
    messages: list[dict] = [{"role": "system", "content": persona}]
    # turns is what we log (readable version)
    turns: list[dict] = [{"role": "system", "content": persona}]

    # ---------------------------------------------------------------------------
    # Header
    # ---------------------------------------------------------------------------
    os.system("clear" if os.name != "nt" else "cls")
    print(bold("╔══════════════════════════════════════════════════════╗"))
    print(bold("║        Project Aeria — Council Chat                 ║"))
    print(bold("╚══════════════════════════════════════════════════════╝"))
    print(f"  Agent    : {cyan('@' + current_agent.title())}")
    print(f"  Endpoint : {dim(f'http://{args.host}:{args.port}')}")
    print(f"  RAG      : {green('enabled') if use_rag else yellow('disabled')}")
    print(f"  Archive  : {dim(str(aeria_root / '03_THE_ARCHIVES'))}")
    print(f"  {dim('Type /help for commands. /bye to exit.')}")
    print()

    # ---------------------------------------------------------------------------
    # Chat loop
    # ---------------------------------------------------------------------------
    while True:
        # Prompt
        try:
            prompt_label = f"{cyan(f'@{current_agent.title()}')} {bold('›')} "
            user_input = input(prompt_label).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not user_input:
            continue

        # ── Commands ────────────────────────────────────────────────────────
        if user_input.startswith("/"):
            parts = user_input.split(None, 1)
            cmd   = parts[0].lower()
            arg   = parts[1] if len(parts) > 1 else ""

            if cmd in ("/bye", "/quit", "/exit"):
                break

            elif cmd == "/help":
                print(COMMANDS)

            elif cmd == "/clear":
                persona = load_persona(current_agent)
                messages = [{"role": "system", "content": persona}]
                turns    = [{"role": "system", "content": persona}]
                print(dim("  Conversation cleared. Starting fresh."))

            elif cmd == "/agent":
                new_agent = arg.lower().strip()
                if new_agent not in AGENTS:
                    print(red(f"  Unknown agent. Choose: {', '.join(AGENTS)}"))
                else:
                    current_agent = new_agent
                    persona = load_persona(current_agent)
                    # Inject agent switch as a new system context
                    messages = [{"role": "system", "content": persona}]
                    turns    = [{"role": "system", "content": persona}]
                    print(green(f"  Switched to @{current_agent.title()}. History cleared."))

            elif cmd == "/rag":
                if arg.lower() == "on":
                    use_rag = True
                    print(green("  RAG enabled — archive context will be retrieved."))
                elif arg.lower() == "off":
                    use_rag = False
                    print(yellow("  RAG disabled — no archive context will be retrieved."))
                else:
                    state = green("on") if use_rag else yellow("off")
                    print(f"  RAG is currently {state}. Use /rag on or /rag off.")

            elif cmd == "/context":
                # Rough token estimate: 1 token ≈ 4 chars
                total_chars = sum(len(m["content"]) for m in messages)
                est_tokens  = total_chars // 4
                print(f"  {len(messages)} messages, ~{est_tokens} tokens in context window.")

            elif cmd == "/save":
                path = save_transcript(log_dir, current_agent, turns)
                print(green(f"  Saved: {path}"))

            else:
                print(yellow(f"  Unknown command: {cmd}. Type /help for list."))

            continue

        # ── Normal query ─────────────────────────────────────────────────────

        # Retrieve RAG context for this specific question
        context_block = ""
        if use_rag:
            context_block = get_rag_context(user_input, aeria_root, args.rag_top_k)

        # Build the message to send — embed context inline so it's per-turn
        if context_block:
            user_message = f"{context_block}\n\nQUESTION: {user_input}"
            rag_indicator = dim(f" [{context_block.count('─' * 56)} archive chunk(s)]")
        else:
            user_message = user_input
            rag_indicator = ""

        messages.append({"role": "user", "content": user_message})
        turns.append({"role": "user", "content": user_input})  # log clean version

        # Call the model
        print(dim(f"  Consulting @{current_agent.title()}...{rag_indicator}"))
        try:
            response = chat(
                messages    = messages,
                host        = args.host,
                port        = args.port,
                max_tokens  = args.max_tokens,
                temperature = args.temperature,
            )
        except ConnectionError as exc:
            print(red(f"\n  {exc}\n"))
            messages.pop()   # remove the failed user message
            turns.pop()
            continue
        except RuntimeError as exc:
            print(red(f"\n  Model error: {exc}\n"))
            messages.pop()
            turns.pop()
            continue

        messages.append({"role": "assistant", "content": response})
        turns.append({"role": "assistant", "content": response})

        # Print response
        print()
        print(bold(f"  @{current_agent.upper()}"))
        print(bold("  " + "─" * 54))
        # Indent each line of the response
        for line in response.splitlines():
            print(f"  {line}")
        print()

    # ---------------------------------------------------------------------------
    # On exit — save transcript
    # ---------------------------------------------------------------------------
    if len(turns) > 1:   # more than just the system prompt
        path = save_transcript(log_dir, current_agent, turns)
        print(dim(f"\n  Transcript saved: {path}"))
    print(dim("  Session ended.\n"))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse
    p = argparse.ArgumentParser(
        prog="council_chat.py",
        description="Project Aeria — Council Interactive Chat",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 council_chat.py --agent surgeon
  python3 council_chat.py --agent blacksmith --no-rag
  python3 council_chat.py --agent engineer --host 127.0.0.1 --port 8080

In-session commands:
  /agent surgeon|blacksmith|engineer   Switch agent
  /rag on|off                          Toggle archive retrieval
  /clear                               Reset conversation history
  /context                             Show context window usage
  /save                                Save transcript now
  /bye                                 Exit
""",
    )
    p.add_argument("--agent",       required=True, choices=list(AGENTS),
                   help="Council member to consult")
    p.add_argument("--root",        default=None,
                   help="AERIA_ROOT (default: two levels above this script)")
    p.add_argument("--host",        default="127.0.0.1")
    p.add_argument("--port",        type=int, default=8080)
    p.add_argument("--max-tokens",  type=int, default=2048)
    p.add_argument("--temperature", type=float, default=0.2)
    p.add_argument("--rag-top-k",   type=int, default=3)
    p.add_argument("--no-rag",      action="store_true",
                   help="Disable archive context retrieval")
    run_chat(p.parse_args())


if __name__ == "__main__":
    main()
