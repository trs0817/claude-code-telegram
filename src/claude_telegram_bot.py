#!/usr/bin/env python3
"""
claude-code-telegram — Telegram bridge to the Claude Code CLI.

Thin pass-through: only /help and /more are handled in-bot; everything else
is forwarded to `claude -p` in the configured project directory with the
chosen session mode, so vault slash commands and SKILL.md files run
server-side just like in a local terminal session.

Configuration is via environment variables; see config/.env.example.

Repository: https://github.com/trs0817/claude-code-telegram
License: MIT
"""

from __future__ import annotations

import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Callable

import requests

__version__ = "1.1.0"


# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
def _env_int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, default))
    except ValueError:
        sys.stderr.write(f"Warning: {key} is not an integer; using default {default}\n")
        return default


def _env_bool(key: str, default: bool) -> bool:
    val = os.environ.get(key)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


# SESSION_MODE values: "threaded" | "stateless" | "dedicated"
# threaded  → claude --continue -p  (shares session with terminal use)
# stateless → claude -p             (fresh context per message)
# dedicated → claude --session-id <SESSION_ID> -p  (isolated fixed session)
_SESSION_MODE = os.environ.get("SESSION_MODE", "threaded").strip().lower()
if _SESSION_MODE not in ("threaded", "stateless", "dedicated"):
    sys.stderr.write(
        f"Warning: SESSION_MODE '{_SESSION_MODE}' is not valid; using 'threaded'\n"
    )
    _SESSION_MODE = "threaded"

CONFIG = {
    "BOT_TOKEN":     os.environ.get("TELEGRAM_BOT_TOKEN", ""),
    "CHAT_ID":       os.environ.get("TELEGRAM_CHAT_ID", ""),
    "VAULT_PATH":    os.environ.get("VAULT_PATH", ""),
    "CLAUDE_BIN":    os.environ.get("CLAUDE_BIN", "claude"),
    "SESSION_MODE":  _SESSION_MODE,
    "SESSION_ID":    os.environ.get("SESSION_ID", ""),     # required if dedicated
    "RESPONSE_FMT":  os.environ.get("RESPONSE_FORMAT", "markdown").strip().lower(),
    "TYPING":        _env_bool("TYPING_INDICATOR", True),
    "TIMEOUT":       _env_int("CLAUDE_TIMEOUT", 90),
    "MAX_CHUNKS":    _env_int("MAX_CHUNKS", 3),
    "CHUNK_SIZE":    _env_int("CHUNK_SIZE", 3800),
    "POLL_INTERVAL": _env_int("POLL_INTERVAL", 2),
}


# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("claude-code-telegram")


# ─────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────
state = {
    "last_update_id": 0,
    "pending_chunks": [],
    "processing": False,
}

_ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


# ─────────────────────────────────────────────
# TELEGRAM I/O
# ─────────────────────────────────────────────
def tg_url(method: str) -> str:
    return f"https://api.telegram.org/bot{CONFIG['BOT_TOKEN']}/{method}"


def send_message(text: str, parse_mode: str | None = None) -> None:
    # In plain-text mode never send a Markdown parse_mode
    if CONFIG["RESPONSE_FMT"] == "plain":
        parse_mode = None
    payload = {"chat_id": CONFIG["CHAT_ID"], "text": text}
    if parse_mode:
        payload["parse_mode"] = parse_mode
    try:
        r = requests.post(tg_url("sendMessage"), data=payload, timeout=10)
        r.raise_for_status()
    except Exception as e:
        log.error("Failed to send message: %s", e)


def send_typing() -> None:
    if not CONFIG["TYPING"]:
        return
    try:
        requests.post(
            tg_url("sendChatAction"),
            data={"chat_id": CONFIG["CHAT_ID"], "action": "typing"},
            timeout=5,
        )
    except Exception:
        pass


def get_updates(offset: int = 0) -> list:
    try:
        r = requests.get(
            tg_url("getUpdates"),
            params={"offset": offset, "timeout": 30},
            timeout=35,
        )
        r.raise_for_status()
        return r.json().get("result", [])
    except Exception as e:
        log.error("get_updates error: %s", e)
        return []


# ─────────────────────────────────────────────
# CHUNKING
# ─────────────────────────────────────────────
def chunk_text(text: str, size: int | None = None) -> list[str]:
    """Split text into pieces, preferring newline boundaries near the limit."""
    size = size or CONFIG["CHUNK_SIZE"]
    chunks: list[str] = []
    while len(text) > size:
        split_at = text.rfind("\n", size - 200, size)
        if split_at == -1:
            split_at = size
        chunks.append(text[:split_at].rstrip())
        text = text[split_at:].lstrip()
    if text:
        chunks.append(text)
    return chunks


def send_chunked(text: str) -> None:
    parse_mode = "Markdown" if CONFIG["RESPONSE_FMT"] == "markdown" else None
    chunks = chunk_text(text)
    state["pending_chunks"] = []
    if not chunks:
        msg = "_(empty response)_" if parse_mode else "(empty response)"
        send_message(msg, parse_mode=parse_mode)
        return

    max_c = CONFIG["MAX_CHUNKS"]
    to_send = chunks[:max_c]
    leftover = chunks[max_c:]

    for i, chunk in enumerate(to_send):
        if len(chunks) > 1 and parse_mode:
            label = f"*[{i + 1}/{len(chunks)}]*\n"
        elif len(chunks) > 1:
            label = f"[{i + 1}/{len(chunks)}]\n"
        else:
            label = ""
        send_message(label + chunk, parse_mode=parse_mode)
        time.sleep(0.3)

    if leftover:
        state["pending_chunks"] = leftover
        remaining_chars = sum(len(c) for c in leftover)
        if parse_mode:
            more_msg = (
                f"⏩ *Response truncated.* {len(leftover)} more chunk(s) "
                f"(~{remaining_chars} chars).\nReply `/more` to continue."
            )
        else:
            more_msg = (
                f"⏩ Response truncated. {len(leftover)} more chunk(s) "
                f"(~{remaining_chars} chars). Reply /more to continue."
            )
        send_message(more_msg, parse_mode=parse_mode)


# ─────────────────────────────────────────────
# CLAUDE INVOCATION
# ─────────────────────────────────────────────
def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _build_claude_cmd(prompt: str) -> list[str]:
    """Build the claude invocation list based on SESSION_MODE."""
    base = [CONFIG["CLAUDE_BIN"]]
    mode = CONFIG["SESSION_MODE"]
    if mode == "threaded":
        flags = ["--continue"]
    elif mode == "dedicated":
        flags = ["--session-id", CONFIG["SESSION_ID"]]
    else:  # stateless
        flags = []
    return base + flags + ["-p", prompt]


def run_claude(prompt: str) -> tuple[str | None, str | None]:
    """
    Run claude in the configured session mode.
    Returns (stdout, error_message).
    For threaded mode: if --continue fails on a fresh dir, retries without it
    so the first-ever invocation still works.
    """
    work_dir = CONFIG["VAULT_PATH"]
    cmd = _build_claude_cmd(prompt)
    log.info("Running: %s in %s", cmd, work_dir)

    try:
        result = subprocess.run(
            cmd, cwd=work_dir, capture_output=True, text=True,
            timeout=CONFIG["TIMEOUT"],
        )
        stdout = strip_ansi(result.stdout).strip()
        stderr = strip_ansi(result.stderr).strip()

        # Threaded-mode fallback: --continue fails on a brand-new directory
        if CONFIG["SESSION_MODE"] == "threaded" and result.returncode != 0 and not stdout:
            log.info("--continue failed (rc=%s), retrying without", result.returncode)
            result = subprocess.run(
                [CONFIG["CLAUDE_BIN"], "-p", prompt],
                cwd=work_dir, capture_output=True, text=True,
                timeout=CONFIG["TIMEOUT"],
            )
            stdout = strip_ansi(result.stdout).strip()
            stderr = strip_ansi(result.stderr).strip()

        if result.returncode != 0 and not stdout:
            return None, stderr or f"Claude exited with code {result.returncode}"
        return stdout or "(no output)", None

    except subprocess.TimeoutExpired:
        return None, f"⏱ Claude timed out after {CONFIG['TIMEOUT']}s."
    except FileNotFoundError:
        return None, f"Claude binary not found at: {CONFIG['CLAUDE_BIN']}"
    except Exception as e:
        return None, f"Unexpected error: {e}"


# ─────────────────────────────────────────────
# BOT-INTERNAL COMMANDS
# ─────────────────────────────────────────────
def handle_help(_args: str) -> None:
    mode = CONFIG["SESSION_MODE"]
    mode_desc = {
        "threaded":  "threaded (--continue, shares terminal session)",
        "stateless": "stateless (fresh context per message)",
        "dedicated": f"dedicated (isolated session ID: ...{CONFIG['SESSION_ID'][-8:] if CONFIG['SESSION_ID'] else 'unset'})",
    }.get(mode, mode)

    fmt = CONFIG["RESPONSE_FMT"]
    typing = "on" if CONFIG["TYPING"] else "off"
    parse_mode = "Markdown" if fmt == "markdown" else None

    if parse_mode:
        help_text = (
            f"🤖 *claude-code-telegram v{__version__}*\n\n"
            "*Bot-internal commands:*\n"
            "`/help` — this message\n"
            "`/more` — continue a long response\n\n"
            "*Everything else* is passed through to `claude -p`.\n"
            "Your project's slash commands and SKILL.md files run server-side.\n\n"
            f"Project: `{CONFIG['VAULT_PATH']}`\n"
            f"Session: {mode_desc}\n"
            f"Format: {fmt} | Typing: {typing}\n"
            f"Timeout: {CONFIG['TIMEOUT']}s | Max chunks: {CONFIG['MAX_CHUNKS']}"
        )
    else:
        help_text = (
            f"claude-code-telegram v{__version__}\n\n"
            "Bot-internal commands:\n"
            "/help — this message\n"
            "/more — continue a long response\n\n"
            "Everything else is passed through to claude -p.\n"
            "Your project's slash commands and SKILL.md files run server-side.\n\n"
            f"Project: {CONFIG['VAULT_PATH']}\n"
            f"Session: {mode_desc}\n"
            f"Format: {fmt} | Typing: {typing}\n"
            f"Timeout: {CONFIG['TIMEOUT']}s | Max chunks: {CONFIG['MAX_CHUNKS']}"
        )
    send_message(help_text, parse_mode=parse_mode)


def handle_more(_args: str) -> None:
    parse_mode = "Markdown" if CONFIG["RESPONSE_FMT"] == "markdown" else None
    if not state["pending_chunks"]:
        send_message("No pending response. Ask me something first.")
        return
    max_c = CONFIG["MAX_CHUNKS"]
    to_send = state["pending_chunks"][:max_c]
    leftover = state["pending_chunks"][max_c:]
    for chunk in to_send:
        send_message(chunk, parse_mode=parse_mode)
        time.sleep(0.3)
    if leftover:
        state["pending_chunks"] = leftover
        cont = "`/more`" if parse_mode else "/more"
        send_message(f"⏩ {len(leftover)} more chunk(s). Reply {cont} to continue.", parse_mode=parse_mode)
    else:
        state["pending_chunks"] = []


BOT_COMMANDS: dict[str, Callable[[str], None]] = {
    "/help":  handle_help,
    "/more":  handle_more,
    "/start": handle_help,
}


# ─────────────────────────────────────────────
# MESSAGE ROUTER
# ─────────────────────────────────────────────
def handle_message(text: str) -> None:
    text = text.strip()
    if text.startswith("/"):
        first_word = text.split(" ", 1)[0].split("@")[0].lower()
        if first_word in BOT_COMMANDS:
            args = text.split(" ", 1)[1] if " " in text else ""
            BOT_COMMANDS[first_word](args)
            return
        # else: pass through to claude (e.g. /save, /lint, custom SKILL.md commands)

    if state["processing"]:
        send_message("⏳ Still working on previous request. Please wait.")
        return

    state["processing"] = True
    send_typing()
    try:
        output, err = run_claude(text)
        if err:
            send_message(f"❌ {err}")
        else:
            send_chunked(output)
    finally:
        state["processing"] = False


# ─────────────────────────────────────────────
# POLL LOOP
# ─────────────────────────────────────────────
def poll() -> None:
    log.info("Bot started (v%s). Polling for messages...", __version__)
    mode = CONFIG["SESSION_MODE"]
    send_message(f"🟢 Claude Code bot online (session: {mode}). Type /help for commands.")
    while True:
        updates = get_updates(offset=state["last_update_id"] + 1)
        for update in updates:
            state["last_update_id"] = update["update_id"]
            message = update.get("message") or update.get("edited_message")
            if not message:
                continue
            chat_id = str(message.get("chat", {}).get("id", ""))
            if chat_id != str(CONFIG["CHAT_ID"]):
                log.warning("Ignored message from unauthorized chat_id: %s", chat_id)
                continue
            text = message.get("text", "").strip()
            if not text:
                continue
            log.info("Received: %s", text[:80])
            t = threading.Thread(target=handle_message, args=(text,), daemon=True)
            t.start()
        time.sleep(CONFIG["POLL_INTERVAL"])


# ─────────────────────────────────────────────
# CONFIG VALIDATION
# ─────────────────────────────────────────────
def validate_config() -> None:
    errors = []
    if not CONFIG["BOT_TOKEN"]:
        errors.append("TELEGRAM_BOT_TOKEN is not set")
    if not CONFIG["CHAT_ID"]:
        errors.append("TELEGRAM_CHAT_ID is not set")
    if not CONFIG["VAULT_PATH"]:
        errors.append("VAULT_PATH is not set (the project directory claude operates in)")
    elif not os.path.isdir(CONFIG["VAULT_PATH"]):
        errors.append(f"VAULT_PATH does not exist: {CONFIG['VAULT_PATH']}")
    if CONFIG["SESSION_MODE"] == "dedicated" and not CONFIG["SESSION_ID"]:
        errors.append(
            "SESSION_MODE is 'dedicated' but SESSION_ID is not set. "
            "Generate one with: python3 -c \"import uuid; print(uuid.uuid4())\""
        )
    if CONFIG["RESPONSE_FMT"] not in ("markdown", "plain"):
        errors.append(
            f"RESPONSE_FORMAT '{CONFIG['RESPONSE_FMT']}' is invalid. "
            "Use 'markdown' or 'plain'."
        )
    if errors:
        sys.stderr.write("Configuration errors:\n")
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(
            "\nSee config/.env.example or run the installer:\n"
            "  curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram"
            "/main/bootstrap.sh | bash\n"
        )
        sys.exit(2)


def handle_shutdown(_sig, _frame) -> None:
    log.info("Shutting down.")
    try:
        send_message("🔴 Claude Code bot offline.")
    except Exception:
        pass
    sys.exit(0)


def main() -> None:
    if "--version" in sys.argv:
        print(f"claude-code-telegram {__version__}")
        sys.exit(0)
    if "--check" in sys.argv:
        validate_config()
        print("Config OK")
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_shutdown)
    signal.signal(signal.SIGTERM, handle_shutdown)
    validate_config()
    poll()


if __name__ == "__main__":
    main()
