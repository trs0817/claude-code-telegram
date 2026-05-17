# claude-code-telegram

> A Telegram bot that bridges your phone to the [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI running on a homelab server, with full project/vault context and cross-message conversation continuity.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9+-blue.svg)](https://www.python.org/downloads/)
[![CI](https://github.com/trs0817/claude-code-telegram/actions/workflows/ci.yml/badge.svg)](https://github.com/trs0817/claude-code-telegram/actions/workflows/ci.yml)
[![systemd](https://img.shields.io/badge/systemd-ready-green.svg)](systemd/)

---

## What it is

A thin pass-through bot. Every Telegram message becomes a `claude -p <prompt>` invocation in your project directory on the server. The bot itself only knows two commands (`/help`, `/more`); everything else — including your vault's slash commands and `.claude/commands/*.md` files — runs server-side exactly as it would in a local terminal.

If you keep notes in [Obsidian](https://obsidian.md/) or any other markdown vault that you also use `claude` against, this gives you a mobile interface to that same workflow: read your notes, query them, save new notes, lint links, whatever your existing skills do — all from your phone.

## Quick start

Prerequisites: a Linux server with systemd, Python 3.9+, and [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and authenticated.

```bash
curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash
```

The wizard will:
- detect your Obsidian vault automatically
- fetch your Telegram chat ID by having you send a test message
- walk you through session mode and response preferences
- deploy a hardened systemd service and start it

You'll receive a 🟢 online message in Telegram when it's running.

See [docs/INSTALL.md](docs/INSTALL.md) for a manual deploy or [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something goes sideways.

## Getting a bot token

1. DM [`@BotFather`](https://t.me/BotFather) on Telegram, send `/newbot`, follow the prompts.
2. Copy the token from the final message.
3. Run the installer — it handles your chat ID automatically.

The bot only responds to the configured chat ID — every other sender is silently ignored. Treat the token like an SSH private key.

## Architecture

```
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│   Telegram   │   long   │  bot script  │  spawn   │    claude    │
│   (phone)    │◄────────►│  (systemd)   │─────────►│    -p ...    │
└──────────────┘  poll    └──────────────┘          └──────┬───────┘
                                                           │
                                                           ▼
                                                   ┌──────────────┐
                                                   │  your vault  │
                                                   │  (cwd)       │
                                                   └──────────────┘
```

The bot is **not** a wrapper around the Claude API. It shells out to the real `claude` CLI, which means everything Claude Code does — vault skills, slash commands, hooks, settings.json, project memory — works without re-implementation.

## Session modes

Configured during install (or via `SESSION_MODE` in `/etc/claude-code-telegram.env`):

| Mode | How it works | Use when |
|---|---|---|
| `threaded` | Uses `--continue`, resuming the most recent claude session in your vault | You want messages to build on each other and don't mind sharing context with terminal claude sessions |
| `dedicated` | Uses `--session-id <fixed-uuid>`, an isolated session only the bot touches | You want continuity without bleed into terminal sessions |
| `stateless` | No session flag — each message starts fresh | You want maximum independence between messages |

## Configuration

All config lives in `/etc/claude-code-telegram.env` (written by the installer, permissions 0600).

| Variable | Required | Default | Description |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | — | Token from `@BotFather` |
| `TELEGRAM_CHAT_ID` | yes | — | The only chat the bot responds to |
| `VAULT_PATH` | yes | — | Project directory `claude` runs in (cwd) |
| `SESSION_MODE` | no | `threaded` | `threaded`, `dedicated`, or `stateless` |
| `SESSION_ID` | if dedicated | — | UUID for the dedicated session |
| `RESPONSE_FORMAT` | no | `markdown` | `markdown` or `plain` |
| `TYPING_INDICATOR` | no | `1` | `1` to show typing animation, `0` to disable |
| `CLAUDE_BIN` | no | `claude` | Full path to claude binary |
| `CLAUDE_TIMEOUT` | no | `90` | Seconds before killing a hung `claude` call |
| `MAX_CHUNKS` | no | `3` | Max chunks sent before offering `/more` |
| `CHUNK_SIZE` | no | `3800` | Chars per Telegram message (Telegram limit is 4096) |
| `POLL_INTERVAL` | no | `2` | Seconds between long-poll cycles |

See [config/.env.example](config/.env.example) for an annotated reference.

## Bot commands

| Command | Behavior |
|---|---|
| `/help` | Show config and bot-internal commands |
| `/more` | Send next batch of chunks after a truncated response |
| anything else | Forwarded verbatim to `claude -p` in your vault |

Your project's slash commands (`/save`, `/lint`, custom ones) are invoked by Claude itself — the bot does **not** intercept them.

## Security

- The chat ID allowlist is the only access gate. Treat the bot token like an SSH key.
- The bot runs as a non-root system user chosen during install.
- All config (including the token) lives in a 0600-protected env file — it never appears in `journalctl output` or `systemctl status`.
- Claude inherits the file-write permissions of the service user.
- See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Development

```bash
python3 -m py_compile src/claude_telegram_bot.py
ruff check src/
pytest tests/
```

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Built on top of [Claude Code](https://docs.claude.com/en/docs/claude-code) by Anthropic. Inspired by the Obsidian + AI workflow community.
