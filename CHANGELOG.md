# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.1] — 2026-05-18

### Added

- **Automatic update notifications** — installer drops a weekly cron (`/etc/cron.d/claude-code-telegram-update`) that checks GitHub for new releases and pings you via `claude-notify` when one is available
- **VERSION file** — installer writes installed version to `/usr/local/share/claude-code-telegram/VERSION`; update check reads it dynamically so no hardcoding needed after each update
- **`check-cct-update` helper** — installed to `/usr/local/bin/check-cct-update`; can also be run manually at any time

## [2.0.0] — 2026-05-17

### Added

- **Plan-before-execute safety flow** — in `safe` permission mode (default), Claude first describes what it's going to do; you approve with `/go` or cancel with `/cancel` before any changes are written
- **`/trust` command** — bypasses the plan step for the rest of the session (use when you know what you're asking for)
- **`/status` command** — shows current session mode, permission mode, session ID, vault path, and whether a task is in flight
- **`/new` command** — resets the session (clears trust, pending actions, starts a fresh Claude conversation)
- **`/retry` command** — re-runs the most recent prompt without retyping it (useful after a timeout or partial response)
- **`/go` and `/cancel` commands** — explicit confirmation/rejection of the pending plan in `safe` mode
- **`ALLOWED_USERS` config** — comma-separated list of chat IDs; replaces single `TELEGRAM_CHAT_ID` (backward-compatible; old variable still works)
- **`PERMISSION_MODE` config** — `safe` (plan-then-execute, default) or `unrestricted` (direct `--dangerously-skip-permissions`, equivalent to old `/trust` behaviour always on)
- **`claude-notify` utility** — installed to `/usr/local/bin/claude-notify`; sends Telegram push notifications from any script or cron job; supports silent mode (`-s`), stdin pipe, and reads credentials from the shared env file
- **`SESSION_MODE=dedicated`** — new `--session-id <uuid>` mode isolates the bot's conversation from terminal Claude sessions
- **`RESPONSE_FORMAT` config** — `markdown` (default) or `plain`; controls whether Claude is instructed to avoid markdown formatting
- **`TYPING_INDICATOR` config** — toggle the "typing…" animation in Telegram (0 to disable, 1 default)
- **`--dry-run` installer flag** — walks the full 8-step wizard and prints every action it would take without writing any files or starting the service
- **`--update` installer flag** — re-deploys the bot script and restarts the service while preserving existing config
- **Existing install detection** — installer detects a running service and offers reinstall / reconfigure / cancel instead of clobbering
- **Claude auth preflight** — installer checks `claude --version`, detects auth state, and provides targeted instructions (headless token vs. interactive browser) if auth is missing
- **Vault auto-detection** — installer scans home directories for `.obsidian/` folders and pre-fills the vault path; presents pick-list when multiple vaults are found
- **Telegram chat ID auto-fetch** — installer sends a temporary `getUpdates` poll so you never have to find your chat ID manually; just send any message to your bot when prompted
- **Obsidian + Claude setup suggestion** — installer detects Obsidian vaults and optionally suggests the `claude-vault` skill setup steps
- **Test invocation at install time** — installer runs `claude --version` inside the vault path to confirm subprocess works before starting the service
- **Targeted error diagnosis** — installer catches common failures (missing `claude`, unauth, empty bot token, unreachable Telegram API) with plain-English remediation hints

### Changed

- **Bot core completely rewritten** — single worker-thread + `queue.Queue` model; all state mutations happen in one thread, eliminating race conditions between commands and in-flight Claude invocations
- **`SessionState` class** — replaces loose `dict` for cleaner state management and explicit fields
- **`--continue` fallback** — first invocation in `threaded` mode gracefully retries without `--continue` if no prior session exists in the vault
- **Installer is now an 8-step interactive wizard** — all `printf` / `read` calls route to `/dev/tty` so the script is safely composable inside `$()` captures without prompt leakage
- **Runtime directory** — bot script now lives in `/opt/claude-code-telegram/` (previously co-located with the repo)
- **`uninstall.sh`** — now offers to keep the config file for future reinstalls; also removes `claude-notify`
- **`bootstrap.sh`** — passes all flags (e.g. `--dry-run`, `--update`) through to the installer via `"$@"`

### Fixed

- Empty bot token input no longer kills the installer; the wizard loops until a non-empty value is provided
- Python 3.9 compatibility: replaced `str | None` union syntax (requires 3.10+) with `Optional[str]` from `typing`
- `/go`, `/cancel`, and `/more` no longer race with the worker thread; all commands are now routed through the queue

## [1.0.0] — 2026-05-17

### Added

- Telegram long-poll loop with chat-ID allowlist
- Pass-through to `claude -p`; only `/help`, `/more`, `/start` are bot-internal
- `--continue` flag on every claude invocation for conversation continuity, with automatic fallback to a stateless invocation if `--continue` fails
- Response chunking (configurable size, default 3,800 chars × 3 chunks before offering `/more`)
- ANSI-escape stripping on claude output (Telegram doesn't render terminal control codes)
- Concurrent-request guard — the bot replies "still working" if a claude invocation is in flight
- Online/offline notifications on service start and stop (SIGTERM/SIGINT)
- `--check` flag for validating config without starting the poller
- `--version` flag
- Templated systemd unit with sensible hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths`)
- Interactive `install.sh` that detects prerequisites, prompts for config, writes