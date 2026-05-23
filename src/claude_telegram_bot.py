#!/usr/bin/env python3
"""
claude-code-telegram — Telegram bridge to the Claude Code CLI.

Architecture:
  - Main thread: long-poll Telegram, enqueue every incoming message
  - Worker thread: dequeue one message at a time, route to handler
  - All state mutations happen in the worker — no locks needed

Features:
  - Message queue: messages pile up while Claude is thinking
  - Plan-before-execute: safe mode shows Claude's plan first
  - /trust: skip plan confirmations for the rest of the session
  - /new: reset session and trust state
  - /status: show current bot state
  - /retry: re-run the last prompt
  - /more: get next chunk of a long response
  - /go /cancel: confirm or abort a pending plan
  - ALLOWED_USERS: comma-separated list of permitted chat IDs

Repository: https://github.com/trs0817/claude-code-telegram
License: MIT
"""

from __future__ import annotations

import logging
import os
import queue
import html as _html  # noqa: F401 (imported for _html.escape usage)
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from typing import Callable, Dict, List, Optional, Set

import requests

__version__ = "2.1.0"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

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


def _parse_allowed_users() -> Set[str]:
    """Parse ALLOWED_USERS (comma-separated), falling back to TELEGRAM_CHAT_ID."""
    raw = os.environ.get("ALLOWED_USERS", "").strip()
    if raw:
        return {u.strip() for u in raw.split(",") if u.strip()}
    fallback = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    return {fallback} if fallback else set()


def _parse_session_mode() -> str:
    mode = os.environ.get("SESSION_MODE", "threaded").strip().lower()
    if mode not in ("threaded", "stateless", "dedicated"):
        sys.stderr.write(f"Warning: SESSION_MODE '{mode}' invalid; using 'threaded'\n")
        return "threaded"
    return mode


def _parse_permission_mode() -> str:
    mode = os.environ.get("PERMISSION_MODE", "safe").strip().lower()
    if mode not in ("safe", "unrestricted"):
        sys.stderr.write(f"Warning: PERMISSION_MODE '{mode}' invalid; using 'safe'\n")
        return "safe"
    return mode


CONFIG: Dict[str, object] = {
    "BOT_TOKEN":       os.environ.get("TELEGRAM_BOT_TOKEN", ""),
    "CHAT_ID":         os.environ.get("TELEGRAM_CHAT_ID", ""),
    "ALLOWED_USERS":   _parse_allowed_users(),
    "VAULT_PATH":      os.environ.get("VAULT_PATH", ""),
    "CLAUDE_BIN":      os.environ.get("CLAUDE_BIN", "claude"),
    "SESSION_MODE":    _parse_session_mode(),
    "SESSION_ID":      os.environ.get("SESSION_ID", ""),
    "PERMISSION_MODE": _parse_permission_mode(),
    "RESPONSE_FMT":    os.environ.get("RESPONSE_FORMAT", "markdown").strip().lower(),
    "TYPING":          _env_bool("TYPING_INDICATOR", True),
    "TIMEOUT":         _env_int("CLAUDE_TIMEOUT", 90),
    "MAX_CHUNKS":      _env_int("MAX_CHUNKS", 3),
    "CHUNK_SIZE":      _env_int("CHUNK_SIZE", 3800),
    "POLL_INTERVAL":   _env_int("POLL_INTERVAL", 2),
    "QUEUE_MAX":       _env_int("QUEUE_MAX", 100),         # max queued messages (0=unlimited)
    "RATE_LIMIT":      _env_int("RATE_LIMIT", 10),         # max messages/min per user (0=off)
    "TRUST_TTL_HOURS": _env_int("TRUST_TTL_HOURS", 24),   # trust expiry in hours (0=no expiry)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("claude-code-telegram")


def _redact(text: str) -> str:
    """Replace the bot token in a string so it never appears in log output."""
    token = str(CONFIG.get("BOT_TOKEN", ""))
    if token and token in text:
        text = text.replace(token, "***TOKEN***")
    return text


# ---------------------------------------------------------------------------
# Session state
#
# ALL reads and writes happen inside the worker thread.
# The main thread only calls queue.put() which is thread-safe.
# ---------------------------------------------------------------------------

class SessionState:
    """Mutable bot state, accessed exclusively from the worker thread."""

    def __init__(self) -> None:
        self.start_time: datetime = datetime.now()
        self.msg_count: int = 0
        self.trust_mode: bool = False
        self.trust_until: Optional[datetime] = None  # None = no expiry when trust is on
        self.last_prompt: Optional[str] = None
        self.last_chat_id: Optional[str] = None
        # Pending plan awaiting /go or /cancel
        # Keys: prompt, chat_id, plan (the plan text shown to the user)
        self.pending_action: Optional[Dict[str, str]] = None
        # Overflow chunks waiting for /more
        self.pending_chunks: List[str] = []

    def reset(self) -> None:
        """Reset session to a clean state (/new)."""
        self.trust_mode = False
        self.trust_until = None
        self.last_prompt = None
        self.last_chat_id = None
        self.pending_action = None
        self.pending_chunks = []

    @property
    def is_trusted(self) -> bool:
        """True if trust mode is active and has not yet expired."""
        if not self.trust_mode:
            return False
        if self.trust_until is None:
            return True
        if datetime.now() < self.trust_until:
            return True
        # Expired — auto-clear so status commands report accurately
        self.trust_mode = False
        self.trust_until = None
        return False

    @property
    def trust_status_str(self) -> str:
        """Human-readable trust status for /status and /help."""
        if not self.is_trusted:
            return "off"
        if self.trust_until:
            remaining = max(0, int((self.trust_until - datetime.now()).total_seconds() / 60))
            return f"on (~{remaining}m remaining)"
        return "on (no expiry)"

    @property
    def uptime_str(self) -> str:
        elapsed = int((datetime.now() - self.start_time).total_seconds())
        h, rem = divmod(elapsed, 3600)
        m = rem // 60
        return f"{h}h {m}m" if h else f"{m}m"


_state = SessionState()

# Single queue: tuples of (chat_id: str, text: str).
# maxsize prevents unbounded memory growth if Claude is slow.
_queue_max = int(str(CONFIG["QUEUE_MAX"])) or 0  # 0 = unlimited per Queue semantics
_msg_queue: queue.Queue = queue.Queue(maxsize=_queue_max)

_ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

# ---------------------------------------------------------------------------
# Telegram helpers
# ---------------------------------------------------------------------------

def _tg_url(method: str) -> str:
    return f"https://api.telegram.org/bot{CONFIG['BOT_TOKEN']}/{method}"


def send_message(text: str, parse_mode: Optional[str] = None,
                 chat_id: Optional[str] = None) -> None:
    """Send a message to Telegram. Silently logs errors rather than raising."""
    if CONFIG["RESPONSE_FMT"] == "plain":
        parse_mode = None
    target = chat_id or CONFIG["CHAT_ID"]
    payload: Dict[str, str] = {"chat_id": target, "text": text}
    if parse_mode:
        payload["parse_mode"] = parse_mode
    try:
        r = requests.post(_tg_url("sendMessage"), data=payload, timeout=10)
        r.raise_for_status()
    except Exception as exc:
        log.error("send_message failed: %s", _redact(str(exc)))


def _send_typing(chat_id: Optional[str] = None) -> None:
    if not CONFIG["TYPING"]:
        return
    try:
        requests.post(
            _tg_url("sendChatAction"),
            data={"chat_id": chat_id or CONFIG["CHAT_ID"], "action": "typing"},
            timeout=5,
        )
    except Exception:
        pass


def get_updates(offset: int = 0) -> List[dict]:
    """Long-poll Telegram for new updates."""
    try:
        r = requests.get(
            _tg_url("getUpdates"),
            params={"offset": offset, "timeout": 30},
            timeout=35,
        )
        r.raise_for_status()
        return r.json().get("result", [])
    except Exception as exc:
        log.error("get_updates error: %s", _redact(str(exc)))
        return []

# ---------------------------------------------------------------------------
# Response chunking
# ---------------------------------------------------------------------------

def _chunk_text(text: str, size: Optional[int] = None) -> List[str]:
    """Split text into Telegram-safe chunks, breaking at newlines where possible."""
    size = size or int(str(CONFIG["CHUNK_SIZE"]))
    chunks: List[str] = []
    while len(text) > size:
        split_at = text.rfind("\n", size - 200, size)
        if split_at == -1:
            split_at = size
        chunks.append(text[:split_at].rstrip())
        text = text[split_at:].lstrip()
    if text:
        chunks.append(text)
    return chunks


def send_chunked(text: str, chat_id: Optional[str] = None) -> None:
    """Send text, splitting into chunks and offering /more for overflow."""
    parse_mode = "Markdown" if CONFIG["RESPONSE_FMT"] == "markdown" else None
    chunks = _chunk_text(text)
    _state.pending_chunks = []

    if not chunks:
        empty = "_(empty response)_" if parse_mode else "(empty response)"
        send_message(empty, parse_mode=parse_mode, chat_id=chat_id)
        return

    max_c = int(str(CONFIG["MAX_CHUNKS"]))
    to_send = chunks[:max_c]
    leftover = chunks[max_c:]

    for i, chunk in enumerate(to_send):
        if len(chunks) > 1:
            label = (f"*[{i+1}/{len(chunks)}]*\n" if parse_mode
                     else f"[{i+1}/{len(chunks)}]\n")
        else:
            label = ""
        send_message(label + chunk, parse_mode=parse_mode, chat_id=chat_id)
        time.sleep(0.3)

    if leftover:
        _state.pending_chunks = leftover
        remaining = sum(len(c) for c in leftover)
        if parse_mode:
            overflow = (f"⏩ *Response truncated.* {len(leftover)} more chunk(s) "
                        f"(~{remaining} chars).\nReply `/more` to continue.")
        else:
            overflow = (f"⏩ Response truncated. {len(leftover)} more chunk(s) "
                        f"(~{remaining} chars). Reply /more to continue.")
        send_message(overflow, parse_mode=parse_mode, chat_id=chat_id)

# ---------------------------------------------------------------------------
# Prompt construction — prompting best practices
# ---------------------------------------------------------------------------

# Action verbs whose presence in the opening words suggests a write/modify task.
# Used to decide whether to prepend a "think step-by-step" instruction.
_ACTION_WORDS = frozenset({
    "add", "build", "change", "configure", "convert", "create", "debug",
    "delete", "deploy", "edit", "execute", "fix", "generate", "implement",
    "install", "make", "migrate", "modify", "move", "patch", "refactor",
    "remove", "rename", "restart", "rewrite", "run", "set", "setup",
    "start", "update", "write",
})


def _is_action_prompt(prompt: str) -> bool:
    """
    Heuristic: does this prompt ask Claude to DO something rather than explain?
    Checks the first five words for action verbs, or falls back to length.
    """
    first_five = set(prompt.lower().split()[:5])
    return bool(first_five & _ACTION_WORDS) or len(prompt.split()) > 25


def _wrap_prompt(
    prompt: str,
    plan_only: bool = False,
    approved_plan: Optional[str] = None,
    is_first_message: bool = False,
) -> str:
    """
    Apply prompting best practices before sending to the Claude CLI.

    Principles applied:
    - Role/context framing on the first message (avoids redundancy in sessions)
    - "Think step-by-step" for action-oriented requests (leverages reasoning)
    - Explicit, structured output format for planning requests
    - Approved-plan context included verbatim on post-/go execution so Claude
      doesn't re-plan or second-guess what was already reviewed
    - Response format guidance when plain text is configured

    The wrapper is kept intentionally lightweight — it informs Claude's approach
    without drowning the user's actual intent.
    """
    fmt = str(CONFIG["RESPONSE_FMT"])

    # --- Plan-only request -------------------------------------------------
    if plan_only:
        return (
            "Think step-by-step, then provide a concise plan:\n"
            "1. What you will do\n"
            "2. Which files you will read or modify (with paths)\n"
            "3. Any risks or side effects\n\n"
            "Do NOT make any changes yet — describe only.\n\n"
            f"Request: {prompt}"
        )

    # --- Execute after approved plan ---------------------------------------
    if approved_plan:
        # Use fixed-width separators instead of XML tags to prevent tag-injection
        # by user-supplied content breaking the plan/execute boundary.
        return (
            "The following plan has been reviewed and approved by the user. "
            "Execute it now without re-planning.\n\n"
            f"--- APPROVED PLAN ---\n{approved_plan}\n--- END PLAN ---\n\n"
            f"--- ORIGINAL REQUEST ---\n{prompt}\n--- END REQUEST ---"
        )

    # --- Normal execution --------------------------------------------------
    parts: List[str] = []

    # Role context: only on fresh sessions to avoid token waste in long threads
    if is_first_message:
        parts.append(
            "You are running as a homelab assistant accessed via Telegram. "
            "Consult CLAUDE.md and any .claude/commands/ files in this project "
            "for conventions before acting.\n\n"
        )

    # Think-first instruction for writes/complex tasks
    if _is_action_prompt(prompt):
        parts.append(
            "Think step-by-step before making changes. "
            "Consider edge cases and verify the result.\n\n"
        )

    parts.append(prompt)

    if fmt == "plain":
        parts.append("\n\nRespond in plain text without markdown formatting.")

    return "".join(parts)

# ---------------------------------------------------------------------------
# Claude invocation
# ---------------------------------------------------------------------------

def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


# Public aliases used by tests and external callers
strip_ansi = _strip_ansi
chunk_text = _chunk_text

def _build_cmd(prompt: str, plan_only: bool = False) -> List[str]:
    """Build the claude CLI invocation for the configured session and permission mode."""
    base = [str(CONFIG["CLAUDE_BIN"])]

    if plan_only:
        # Plan step: read-only inspection, no session continuity needed
        perm_flags = ["--permission-mode", "plan"]
        session_flags: List[str] = []
    else:
        if CONFIG["PERMISSION_MODE"] == "unrestricted":
            perm_flags = ["--dangerously-skip-permissions"]
        else:
            # safe mode (with or without trust) — file edits allowed, no shell
            perm_flags = ["--permission-mode", "acceptEdits"]

        mode = CONFIG["SESSION_MODE"]
        if mode == "threaded":
            session_flags = ["--continue"]
        elif mode == "dedicated":
            session_flags = ["--session-id", str(CONFIG["SESSION_ID"])]
        else:  # stateless
            session_flags = []

    return base + perm_flags + session_flags + ["-p", prompt]


def run_claude(prompt: str, plan_only: bool = False) -> tuple:
    """
    Invoke the Claude CLI and return (stdout, error_message).

    In threaded mode, automatically retries without --continue if the first
    invocation fails (handles first-ever use in a fresh vault directory).
    """
    work_dir = str(CONFIG["VAULT_PATH"])
    cmd = _build_cmd(prompt, plan_only=plan_only)
    # Log command without the full prompt to avoid persisting user input in journald
    _safe_cmd = cmd[:-1] + ["<prompt>"] if len(cmd) >= 2 and cmd[-2] == "-p" else cmd
    log.info("Running: %s in %s", _safe_cmd, work_dir)

    try:
        result = subprocess.run(
            cmd, cwd=work_dir, capture_output=True, text=True,
            timeout=int(str(CONFIG["TIMEOUT"])),
        )
        stdout = _strip_ansi(result.stdout).strip()
        stderr = _strip_ansi(result.stderr).strip()

        if (not plan_only
                and CONFIG["SESSION_MODE"] == "threaded"
                and result.returncode != 0
                and not stdout):
            log.info("--continue failed (rc=%s); retrying without it", result.returncode)
            fallback_cmd = [c for c in _build_cmd(prompt) if c != "--continue"]
            result = subprocess.run(
                fallback_cmd, cwd=work_dir, capture_output=True, text=True,
                timeout=int(str(CONFIG["TIMEOUT"])),
            )
            stdout = _strip_ansi(result.stdout).strip()
            stderr = _strip_ansi(result.stderr).strip()

        if result.returncode != 0 and not stdout:
            return None, stderr or f"Claude exited with code {result.returncode}"
        return stdout or "(no output)", None

    except subprocess.TimeoutExpired:
        return None, f"⏱ Claude timed out after {CONFIG['TIMEOUT']}s."
    except FileNotFoundError:
        return None, f"Claude binary not found at: {CONFIG['CLAUDE_BIN']}"
    except Exception as exc:
        return None, f"Unexpected error: {_redact(str(exc))}"

# ---------------------------------------------------------------------------
# Bot command handlers
#
# All handlers run in the worker thread — safe to read/write _state directly.
# Signature: handler(args: str, chat_id: str) -> None
# ---------------------------------------------------------------------------

def _parse_mode() -> Optional[str]:
    return "Markdown" if CONFIG["RESPONSE_FMT"] == "markdown" else None


def _md(markdown: str, plain: str, chat_id: Optional[str] = None) -> None:
    """Send markdown or plain variant depending on RESPONSE_FMT."""
    pm = _parse_mode()
    send_message(markdown if pm else plain, parse_mode=pm, chat_id=chat_id)


def handle_help(_args: str, chat_id: str) -> None:
    pm = _parse_mode()
    mode = CONFIG["SESSION_MODE"]
    perm = CONFIG["PERMISSION_MODE"]

    mode_label = {
        "threaded":  "threaded (--continue)",
        "stateless": "stateless (fresh per message)",
        "dedicated": (f"dedicated (ID: …"
                      f"{str(CONFIG['SESSION_ID'])[-8:] if CONFIG['SESSION_ID'] else 'unset'})"),
    }.get(str(mode), str(mode))

    perm_label = "unrestricted ⚠️" if perm == "unrestricted" else "safe (file edits only)"
    trust_note = f" • trust {_state.trust_status_str}" if _state.is_trusted else ""
    queue_note = f" • {_msg_queue.qsize()} queued" if _msg_queue.qsize() else ""
    pending_note = " • plan waiting for /go or /cancel" if _state.pending_action else ""

    if pm:
        text = (
            f"🤖 *claude-code-telegram v{__version__}*\n\n"
            "*Commands:*\n"
            "`/help` — this message\n"
            "`/status` — bot state\n"
            "`/new` — reset session and trust state\n"
            "`/retry` — re-run last prompt\n"
            "`/trust` — skip plan step this session\n"
            "`/trust off` — re-enable plan step\n"
            "`/go` — execute pending plan\n"
            "`/cancel` — abort pending plan\n"
            "`/more` — next chunk of a long response\n\n"
            "*Everything else* is forwarded to `claude -p`.\n"
            "Your vault's slash commands run server-side as normal.\n\n"
            f"*Session:* {mode_label}\n"
            f"*Permissions:* {perm_label}{trust_note}\n"
            f"*Vault:* `{CONFIG['VAULT_PATH']}`\n"
            f"*Timeout:* {CONFIG['TIMEOUT']}s{queue_note}{pending_note}"
        )
    else:
        text = (
            f"claude-code-telegram v{__version__}\n\n"
            "Commands:\n"
            "/help — this message\n"
            "/status — bot state\n"
            "/new — reset session\n"
            "/retry — re-run last prompt\n"
            "/trust — skip plan step\n"
            "/trust off — re-enable plan step\n"
            "/go — execute pending plan\n"
            "/cancel — abort pending plan\n"
            "/more — next chunk\n\n"
            "Everything else goes to claude -p.\n\n"
            f"Session: {mode_label}\n"
            f"Permissions: {perm_label}{trust_note}\n"
            f"Vault: {CONFIG['VAULT_PATH']}\n"
            f"Timeout: {CONFIG['TIMEOUT']}s{queue_note}{pending_note}"
        )
    send_message(text, parse_mode=pm, chat_id=chat_id)


def handle_status(_args: str, chat_id: str) -> None:
    pm = _parse_mode()
    if pm:
        text = (
            f"*Status — v{__version__}*\n\n"
            f"*Uptime:* {_state.uptime_str}\n"
            f"*Session:* {CONFIG['SESSION_MODE']}\n"
            f"*Permissions:* {CONFIG['PERMISSION_MODE']}\n"
            f"*Trust mode:* {_state.trust_status_str}\n"
            f"*Queue depth:* {_msg_queue.qsize()}\n"
            f"*Pending plan:* {'yes — /go or /cancel' if _state.pending_action else 'none'}\n"
            f"*Messages this session:* {_state.msg_count}\n"
            f"*Vault:* `{CONFIG['VAULT_PATH']}`"
        )
    else:
        text = (
            f"Status — v{__version__}\n"
            f"Uptime: {_state.uptime_str}\n"
            f"Session: {CONFIG['SESSION_MODE']}\n"
            f"Permissions: {CONFIG['PERMISSION_MODE']}\n"
            f"Trust mode: {_state.trust_status_str}\n"
            f"Queue: {_msg_queue.qsize()}\n"
            f"Pending plan: {'yes' if _state.pending_action else 'none'}\n"
            f"Messages: {_state.msg_count}\n"
            f"Vault: {CONFIG['VAULT_PATH']}"
        )
    send_message(text, parse_mode=pm, chat_id=chat_id)


def handle_new(_args: str, chat_id: str) -> None:
    _state.reset()
    send_message("🔄 Session reset. Trust mode off.", chat_id=chat_id)


def handle_trust(args: str, chat_id: str) -> None:
    # Trust mode skips the plan/confirm step for both safe and unrestricted modes.
    # A TTL (TRUST_TTL_HOURS) automatically expires trust to limit the blast radius
    # of a compromised session.
    if args.strip().lower() == "off":
        _state.trust_mode = False
        _state.trust_until = None
        _md("🔒 Trust mode *off* — plan confirmation re-enabled.",
            "Trust mode off — plan confirmation re-enabled.", chat_id=chat_id)
    else:
        _state.trust_mode = True
        ttl = int(str(CONFIG["TRUST_TTL_HOURS"]))
        if ttl > 0:
            _state.trust_until = datetime.now() + timedelta(hours=ttl)
            expiry_note = f" (expires in {ttl}h)"
        else:
            _state.trust_until = None
            expiry_note = " (no expiry — use /trust off or /new to revoke)"
        pm = _parse_mode()
        if pm:
            msg = (f"⚡ Trust mode *on* — plan step skipped{expiry_note}.\n"
                   "Send `/trust off` or `/new` to re-enable confirmation.")
        else:
            msg = f"Trust mode on{expiry_note}. Send /trust off or /new to re-enable."
        send_message(msg, parse_mode=pm, chat_id=chat_id)


def handle_retry(_args: str, chat_id: str) -> None:
    if not _state.last_prompt:
        send_message("Nothing to retry yet.", chat_id=chat_id)
        return
    log.info("Retrying last prompt for chat %s", chat_id)
    _execute_prompt(_state.last_prompt, chat_id)


def handle_go(_args: str, chat_id: str) -> None:
    if not _state.pending_action:
        send_message("No pending plan. Send a prompt first.", chat_id=chat_id)
        return
    if _state.pending_action["chat_id"] != chat_id:
        send_message("This plan belongs to a different user.", chat_id=chat_id)
        return
    prompt = _state.pending_action["prompt"]
    approved_plan = _state.pending_action.get("plan")  # pass plan context to execution
    _state.pending_action = None
    send_message("⚙️ Executing...", chat_id=chat_id)
    _execute_prompt(prompt, chat_id, skip_plan=True, approved_plan=approved_plan)


def handle_cancel(_args: str, chat_id: str) -> None:
    if not _state.pending_action:
        send_message("No pending plan to cancel.", chat_id=chat_id)
        return
    _state.pending_action = None
    send_message("❌ Cancelled.", chat_id=chat_id)


def handle_more(_args: str, chat_id: str) -> None:
    pm = _parse_mode()
    if not _state.pending_chunks:
        send_message("No pending response.", chat_id=chat_id)
        return
    max_c = int(str(CONFIG["MAX_CHUNKS"]))
    to_send = _state.pending_chunks[:max_c]
    remaining = _state.pending_chunks[max_c:]
    for chunk in to_send:
        send_message(chunk, parse_mode=pm, chat_id=chat_id)
        time.sleep(0.3)
    if remaining:
        _state.pending_chunks = remaining
        cont = "`/more`" if pm else "/more"
        send_message(
            f"Response continues. Reply {cont} for next chunk "
            f"({len(remaining)} remaining).",
            parse_mode=pm, chat_id=chat_id,
        )
    else:
        _state.pending_chunks = []


# Command registry
_COMMANDS: Dict[str, Callable[[str, str], None]] = {
    "/help":   handle_help,
    "/start":  handle_help,
    "/status": handle_status,
    "/new":    handle_new,
    "/trust":  handle_trust,
    "/retry":  handle_retry,
    "/go":     handle_go,
    "/cancel": handle_cancel,
    "/more":   handle_more,
}

# ---------------------------------------------------------------------------
# Core execution logic
# ---------------------------------------------------------------------------

def _execute_prompt(
    prompt: str,
    chat_id: str,
    skip_plan: bool = False,
    approved_plan: Optional[str] = None,
) -> None:
    """
    Run Claude for a user prompt and send the response.

    Flow:
      safe mode + trust=False + skip_plan=False  → plan first, then wait for /go
      safe mode + trust=True  OR skip_plan=True  → execute immediately (acceptEdits)
      unrestricted mode                          → execute immediately (skip-permissions)

    Called exclusively from the worker thread.
    """
    _state.last_prompt = prompt
    _state.last_chat_id = chat_id
    _state.msg_count += 1

    # True when Claude is starting fresh (no conversation history to rely on)
    is_first = (
        _state.msg_count == 1
        or CONFIG["SESSION_MODE"] == "stateless"
    )

    # Determine whether to run the plan step first.
    # Plan confirmation is required in BOTH safe and unrestricted modes unless the
    # user has active trust (via /trust) or this is a post-/go execution.
    # Unrestricted mode executes with --dangerously-skip-permissions after approval,
    # but still requires human review by default to prevent accidental host RCE.
    needs_plan = not _state.is_trusted and not skip_plan

    if needs_plan:
        _send_typing(chat_id)
        plan_prompt = _wrap_prompt(prompt, plan_only=True)
        plan_out, plan_err = run_claude(plan_prompt, plan_only=True)
        if plan_err:
            send_message(f"Plan step failed: {plan_err}", chat_id=chat_id)
            return
        pm = _parse_mode()
        footer = ("\n\nReply `/go` to execute or `/cancel` to abort." if pm
                  else "\n\nReply /go to execute or /cancel to abort.")
        send_chunked("Claude's plan:\n\n" + (plan_out or "") + footer, chat_id=chat_id)
        # Store prompt AND plan so /go can include both as execution context
        _state.pending_action = {
            "prompt": prompt,
            "chat_id": chat_id,
            "plan": plan_out or "",
        }
        return

    # Wrap prompt with best-practice structure before execution
    wrapped = _wrap_prompt(
        prompt,
        approved_plan=approved_plan,
        is_first_message=is_first,
    )

    _send_typing(chat_id)
    output, err = run_claude(wrapped)
    if err:
        send_message(f"Error: {err}", chat_id=chat_id)
    else:
        send_chunked(output or "", chat_id=chat_id)


def _route(chat_id: str, text: str) -> None:
    """
    Route a single incoming message.
    Bot commands are handled directly; everything else goes to Claude.
    Called exclusively from the worker thread.
    """
    if text.startswith("/"):
        first_word = text.split()[0].split("@")[0].lower()
        if first_word in _COMMANDS:
            args = text.split(" ", 1)[1] if " " in text else ""
            _COMMANDS[first_word](args, chat_id)
            return

    _execute_prompt(text, chat_id)


# ---------------------------------------------------------------------------
# Worker thread
# ---------------------------------------------------------------------------

def _worker() -> None:
    """
    Single worker thread. Dequeues and processes one message at a time.
    All state mutations happen here — no locking required.
    """
    while True:
        chat_id, text = _msg_queue.get()
        try:
            _route(chat_id, text)
        except Exception:
            log.exception("Unhandled error processing message from %s", chat_id)
            try:
                send_message("An unexpected error occurred. Check logs.", chat_id=chat_id)
            except Exception:
                pass
        finally:
            _msg_queue.task_done()


# ---------------------------------------------------------------------------
# Rate limiting (main thread only — accessed exclusively by poll(), no locking needed)
# ---------------------------------------------------------------------------

_rate_buckets: Dict[str, List[float]] = {}


def _is_rate_limited(chat_id: str) -> bool:
    """Return True if chat_id has sent ≥ RATE_LIMIT messages in the last 60 seconds."""
    limit = int(str(CONFIG["RATE_LIMIT"]))
    if limit <= 0:
        return False
    now = time.time()
    window = 60.0
    bucket = _rate_buckets.setdefault(chat_id, [])
    # Prune timestamps outside the sliding window
    _rate_buckets[chat_id] = [t for t in bucket if now - t < window]
    if len(_rate_buckets[chat_id]) >= limit:
        return True
    _rate_buckets[chat_id].append(now)
    return False


# ---------------------------------------------------------------------------
# Poll loop (main thread)
# ---------------------------------------------------------------------------

def poll() -> None:
    """Long-poll Telegram and enqueue incoming messages. Runs in the main thread."""
    log.info("Bot started (v%s). Polling...", __version__)
    send_message(
        f"claude-code-telegram v{__version__} online\n"
        f"Session: {CONFIG['SESSION_MODE']} | Permissions: {CONFIG['PERMISSION_MODE']}\n"
        "Type /help for commands."
    )

    last_update_id = 0
    while True:
        updates = get_updates(offset=last_update_id + 1)
        for update in updates:
            last_update_id = update["update_id"]
            message = update.get("message") or update.get("edited_message")
            if not message:
                continue
            chat_id = str(message.get("chat", {}).get("id", ""))
            allowed: Set[str] = CONFIG["ALLOWED_USERS"]  # type: ignore[assignment]
            if allowed and chat_id not in allowed:
                log.error("Rejected message from unauthorized chat_id: %s", chat_id)
                continue
            text = message.get("text", "").strip()
            if not text:
                continue
            if _is_rate_limited(chat_id):
                log.warning("Rate limit exceeded for chat_id %s — message dropped", chat_id)
                try:
                    send_message(
                        "⚠️ Rate limit exceeded. Please wait before sending another message.",
                        chat_id=chat_id,
                    )
                except Exception:
                    pass
                continue
            log.info("Queuing from %s: %.80s", chat_id, text)
            try:
                _msg_queue.put_nowait((chat_id, text))
            except queue.Full:
                log.warning(
                    "Queue full (%d slots) — dropping message from %s",
                    int(str(CONFIG["QUEUE_MAX"])), chat_id,
                )
                try:
                    send_message(
                        "⚠️ Bot is busy — message dropped. Try again shortly.",
                        chat_id=chat_id,
                    )
                except Exception:
                    pass
        time.sleep(int(str(CONFIG["POLL_INTERVAL"])))


# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------

def validate_config() -> None:
    """Validate required config and exit with a clear message on failure."""
    errors = []

    if not CONFIG["BOT_TOKEN"]:
        errors.append("TELEGRAM_BOT_TOKEN is not set")

    if not CONFIG["ALLOWED_USERS"]:
        errors.append(
            "No users configured. Set ALLOWED_USERS (comma-separated chat IDs) "
            "or TELEGRAM_CHAT_ID."
        )

    if not CONFIG["VAULT_PATH"]:
        errors.append("VAULT_PATH is not set")
    elif not os.path.isdir(str(CONFIG["VAULT_PATH"])):
        errors.append(f"VAULT_PATH does not exist: {CONFIG['VAULT_PATH']}")

    if CONFIG["SESSION_MODE"] == "dedicated" and not CONFIG["SESSION_ID"]:
        errors.append(
            "SESSION_MODE='dedicated' requires SESSION_ID. "
            'Generate: python3 -c "import uuid; print(uuid.uuid4())"'
        )

    if CONFIG["RESPONSE_FMT"] not in ("markdown", "plain"):
        errors.append(
            f"RESPONSE_FORMAT='{CONFIG['RESPONSE_FMT']}' is invalid. "
            "Use 'markdown' or 'plain'."
        )

    if errors:
        sys.stderr.write("Configuration errors:\n")
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(
            "\nSee config/.env.example or reinstall:\n"
            "  curl -sSL https://raw.githubusercontent.com/trs0817/"
            "claude-code-telegram/main/bootstrap.sh | bash\n"
        )
        sys.exit(2)


# ---------------------------------------------------------------------------
# Signal handling and entry point
# ---------------------------------------------------------------------------

def _handle_shutdown(signum: int, frame: object) -> None:
    log.info("Received signal %s - shutting down.", signum)
    try:
        send_message("Claude Code bot offline.")
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

    signal.signal(signal.SIGINT, _handle_shutdown)
    signal.signal(signal.SIGTERM, _handle_shutdown)

    validate_config()

    worker_thread = threading.Thread(target=_worker, name="worker", daemon=True)
    worker_thread.start()

    poll()


if __name__ == "__main__":
    main()
