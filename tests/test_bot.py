"""
Unit tests for claude_telegram_bot.

Focused on the pure functions — chunking and ANSI stripping. The Telegram
I/O and Claude subprocess paths are not unit-tested here; cover those with
integration testing against a real bot and `claude --check` instead.
"""
from __future__ import annotations

import sys
from pathlib import Path

# Make the bot importable without installing as a package
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import claude_telegram_bot as bot  # noqa: E402


class TestChunkText:
    def test_empty_string_returns_empty_list(self):
        assert bot.chunk_text("", size=100) == []

    def test_text_below_size_returns_single_chunk(self):
        text = "hello world"
        assert bot.chunk_text(text, size=100) == [text]

    def test_text_exactly_at_boundary(self):
        text = "a" * 100
        chunks = bot.chunk_text(text, size=100)
        assert chunks == [text]

    def test_text_just_over_boundary(self):
        text = "a" * 101
        chunks = bot.chunk_text(text, size=100)
        assert len(chunks) == 2
        assert "".join(chunks) == text

    def test_long_text_splits_into_multiple_chunks(self):
        text = "a" * 5000
        chunks = bot.chunk_text(text, size=1000)
        assert len(chunks) == 5
        assert "".join(chunks) == text

    def test_prefers_newline_split_point_when_available(self):
        # Build a 250-char text with a newline near char 200
        text = "x" * 200 + "\n" + "y" * 49
        chunks = bot.chunk_text(text, size=210)
        assert len(chunks) == 2
        # First chunk should end before the newline (rstripped)
        assert chunks[0].endswith("x")
        assert chunks[0] == "x" * 200
        assert chunks[1] == "y" * 49

    def test_falls_back_to_hard_split_when_no_newline_nearby(self):
        # No newlines anywhere; should hard-split at `size`
        text = "z" * 1500
        chunks = bot.chunk_text(text, size=500)
        assert len(chunks) == 3
        for c in chunks:
            assert len(c) == 500

    def test_chunks_preserve_round_trip(self):
        text = "line one\nline two\n" + ("padding " * 200) + "\nfinal"
        chunks = bot.chunk_text(text, size=300)
        # Newline/whitespace stripping at boundaries means we don't get strict
        # equality back, but every non-whitespace token should be present
        joined = " ".join(chunks)
        for tok in ("line", "one", "two", "padding", "final"):
            assert tok in joined


class TestStripAnsi:
    def test_strips_color_codes(self):
        text = "\x1b[31mred text\x1b[0m"
        assert bot.strip_ansi(text) == "red text"

    def test_strips_cursor_moves(self):
        text = "\x1b[2Jclear screen"
        assert bot.strip_ansi(text) == "clear screen"

    def test_passes_plain_text_through(self):
        text = "no escapes here, just words"
        assert bot.strip_ansi(text) == text

    def test_handles_empty_string(self):
        assert bot.strip_ansi("") == ""

    def test_handles_only_escapes(self):
        assert bot.strip_ansi("\x1b[31m\x1b[0m") == ""


class TestEnvHelpers:
    def test_env_int_returns_default_when_missing(self, monkeypatch):
        monkeypatch.delenv("TEST_INT", raising=False)
        assert bot._env_int("TEST_INT", 42) == 42

    def test_env_int_parses_valid(self, monkeypatch):
        monkeypatch.setenv("TEST_INT", "7")
        assert bot._env_int("TEST_INT", 42) == 7

    def test_env_int_falls_back_on_invalid(self, monkeypatch):
        monkeypatch.setenv("TEST_INT", "not-a-number")
        assert bot._env_int("TEST_INT", 42) == 42

    def test_env_bool_truthy_values(self, monkeypatch):
        for val in ("1", "true", "yes", "on", "TRUE", "Yes"):
            monkeypatch.setenv("TEST_BOOL", val)
            assert bot._env_bool("TEST_BOOL", False) is True

    def test_env_bool_falsy_values(self, monkeypatch):
        for val in ("0", "false", "no", "off", ""):
            monkeypatch.setenv("TEST_BOOL", val)
            assert bot._env_bool("TEST_BOOL", True) is False

    def test_env_bool_default_when_unset(self, monkeypatch):
        monkeypatch.delenv("TEST_BOOL", raising=False)
        assert bot._env_bool("TEST_BOOL", True) is True
        assert bot._env_bool("TEST_BOOL", False) is False
