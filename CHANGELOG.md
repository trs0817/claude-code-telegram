# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Interactive `install.sh` that detects prerequisites, prompts for config, writes the unit (0600 — token-bearing), and starts the service
- `uninstall.sh` for clean removal
- Optional `notify-on-fail.conf.example` drop-in for integrating with an existing `notify-failure@.service` template
- CI workflow (ruff lint + syntax check + pytest)
- Bug report and feature request issue templates

[Unreleased]: https://github.com/trs0817/claude-code-telegram/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/trs0817/claude-code-telegram/releases/tag/v1.0.0
