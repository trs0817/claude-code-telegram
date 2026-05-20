# claude-code-telegram

> A Telegram bot that bridges your phone to the [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI running on a homelab server — with full project/vault context, conversation continuity, plan-before-execute safety, and push notifications.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9+-blue.svg)](https://www.python.org/downloads/)
[![CI](https://github.com/trs0817/claude-code-telegram/actions/workflows/ci.yml/badge.svg)](https://github.com/trs0817/claude-code-telegram/actions/workflows/ci.yml)
[![systemd](https://img.shields.io/badge/systemd-ready-green.svg)](systemd/)

---

## What it is

Every Telegram message becomes a `claude -p <prompt>` invocation in your project directory on the server. The bot is **not** a wrapper around the Claude API — it shells out to the real `claude` CLI. That means everything Claude Code does natively — vault skills, slash commands, hooks, `settings.json`, project memory — works without re-implementation.

In **safe mode** (default), Claude describes its plan before touching anything. You approve with `/go` or abort with `/cancel`. Flip to **unrestricted mode** (or use `/trust`) when you know what you're asking for.

Push notifications go the other way too: any script on your server can call `claude-notify "message"` to ping you on Telegram.

## Quick start

Prerequisites: a Linux server with systemd, Python 3.9+, and [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and authenticated.

```bash
curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash
```

The installer will:

1. Confirm Claude Code is installed and authenticated
2. Detect your Obsidian vault automatically (or let you enter a path)
3. Walk you through your Telegram bot token and fetch your chat ID automatically
4. Let you pick session mode, permission mode, and response preferences
5. Deploy a hardened systemd service and start it immediately

You'll receive a 🟢 online message in Telegram when it's running.

Want to see what it would do first?

```bash
curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash -s -- --dry-run
```

See [docs/INSTALL.md](docs/INSTALL.md) for a manual deploy or [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something goes sideways.

## Getting a bot token

1. DM [`@BotFather`](https://t.me/BotFather) on Telegram, send `/newbot`, follow the prompts.
2. Copy the token it gives you.
3. Run the installer — it fetches your chat ID automatically by asking you to send a test message.

Treat the token like an SSH private key. It never appears in `journalctl` output or `systemctl status`.

## Architecture

```
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│   Telegram   │   long   │  bot service │  spawn   │    claude    │
│   (phone)    │◄────────►│  (systemd)   │─────────►│    -p ...    │
└──────────────┘  poll    └──────┬───────┘          └──────┬───────┘
                                 │                         │
                          queue.Queue                       ▼
                          (one worker)             ┌──────────────┐
                                                   │  your vault  │
                                                   │  (cwd)       │
                                                   └──────────────┘

any script/cron  ──► claude-notify "msg" ──► Telegram (push)
```

All state mutations happen in a single worker thread consuming a `queue.Queue`. No locks, no races.

## Bot commands

| Command | What it does |
|---|---|
| `/help` | Show all commands and current config |
| `/status` | Session mode, permission mode, session ID, vault path, in-flight status |
| `/new` | Reset session — clears trust, pending actions, starts fresh |
| `/trust` | Skip the plan step for the rest of this session |
| `/retry` | Re-run the most recent prompt |
| `/go` | Approve the pending plan (safe mode) |
| `/cancel` | Abort the pending plan (safe mode) |
| `/more` | Send the next batch of a chunked response |
| anything else | Forwarded verbatim to `claude -p` in your vault |

Your project's slash commands (`/save`, `/lint`, any custom ones) are invoked by Claude itself — the bot does **not** intercept them.

## Permission modes

Configured during install (or via `PERMISSION_MODE` in the env file):

| Mode | How it works |
|---|---|
| `safe` (default) | Claude proposes a plan first; you approve with `/go` or reject with `/cancel` before any writes happen |
| `unrestricted` | Runs with `--dangerously-skip-permissions` — Claude executes immediately without confirmation |

Use `/trust` during a session to temporarily disable the plan step without changing your config.

## Session modes

Configured during install (or via `SESSION_MODE`):

| Mode | How it works | Use when |
|---|---|---|
| `threaded` | `--continue` resumes the most recent claude session in your vault | You want messages to build on each other and don't mind sharing context with terminal claude sessions |
| `dedicated` | `--session-id <uuid>` — an isolated session only the bot touches | You want continuity without bleed into terminal sessions |
| `stateless` | No session flag — each message starts fresh | You want maximum independence between messages |

## Push notifications with `claude-notify`

The installer places a helper at `/usr/local/bin/claude-notify`. Any script or cron job on the server can send you a Telegram message:

```bash
# Basic
claude-notify "Backup complete."

# Silent (no phone buzz)
claude-notify -s "Routine maintenance done."

# Pipe from a command
df -h | claude-notify

# From a cron job
0 3 * * * /usr/local/bin/backup.sh && claude-notify "nightly backup OK" || claude-notify "BACKUP FAILED"
```

Credentials are read from `/etc/claude-code-telegram.env` (the same file the bot uses) — no extra config needed.

## Configuration

All config lives in `/etc/claude-code-telegram.env` (written by the installer, permissions 0600).

| Variable | Required | Default | Description |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | — | Token from `@BotFather` |
| `ALLOWED_USERS` | yes | — | Comma-separated chat IDs allowed to use the bot |
| `VAULT_PATH` | yes | — | Project directory `claude` runs in (cwd) |
| `SESSION_MODE` | no | `threaded` | `threaded`, `dedicated`, or `stateless` |
| `SESSION_ID` | if dedicated | — | UUID for the dedicated session |
| `PERMISSION_MODE` | no | `safe` | `safe` or `unrestricted` |
| `RESPONSE_FORMAT` | no | `markdown` | `markdown` or `plain` |
| `TYPING_INDICATOR` | no | `1` | `1` to show typing animation, `0` to disable |
| `CLAUDE_BIN` | no | `claude` | Full path to claude binary |
| `CLAUDE_TIMEOUT` | no | `90` | Seconds before killing a hung `claude` call |
| `MAX_CHUNKS` | no | `3` | Max chunks sent before offering `/more` |
| `CHUNK_SIZE` | no | `3800` | Chars per message (Telegram limit is 4096) |
| `POLL_INTERVAL` | no | `2` | Seconds between long-poll cycles |

See [config/.env.example](config/.env.example) for an annotated reference.

## Security

- `ALLOWED_USERS` is the only access gate. Treat the bot token like an SSH key.
- The bot runs as a non-root system user chosen during install.
- All config (including the token) lives in a 0600-protected env file — it never appears in `journalctl` or `systemctl status`.
- The service is hardened with `NoNewPrivileges=true`, `ProtectSystem=strict`, and `PrivateTmp=true`.
- Claude inherits the file-write permissions of the service user.
- See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Updating

```bash
curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash -s -- --update
```

Pulls the latest bot script, redeploys it, and restarts the service. Your config is preserved.

## Uninstalling

```bash
sudo ./scripts/uninstall.sh
```

Stops and removes the service, bot script, and `claude-notify`. Offers to keep your config file so a future reinstall can skip the wizard.

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
