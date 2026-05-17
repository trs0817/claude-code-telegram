# Contributing

Thanks for your interest in improving claude-code-telegram. The project is small and the contribution process is light.

## Reporting bugs

Use the [bug report](https://github.com/trs0817/claude-code-telegram/issues/new?template=bug_report.md) template. The most useful bug reports include:

- Output of `journalctl -u claude-code-telegram -n 50 --no-pager` (redact the bot token if it appears)
- `claude --version`, `python3 --version`, `systemctl --version`
- A reproduction — what you sent the bot and what came back

## Proposing features

Open a [feature request](https://github.com/trs0817/claude-code-telegram/issues/new?template=feature_request.md) issue *before* opening a PR, especially for anything that adds a bot-internal command. The architectural goal is to keep the bot a thin pass-through; commands that could live as vault-side `.claude/commands/` skills probably should.

## Submitting changes

1. Fork and branch from `main`.
2. Keep changes focused — one logical change per PR.
3. Run the local checks before opening the PR:
   ```bash
   python3 -m py_compile src/claude_telegram_bot.py
   ruff check src/ tests/
   pytest tests/
   ```
4. If you change behavior, update the relevant section of the [README](README.md) and the [CHANGELOG](CHANGELOG.md) under `## [Unreleased]`.
5. Open the PR against `main`. CI must pass before merge.

## Style

- Python: PEP 8, four-space indent, type hints where they help. `ruff`'s default ruleset is the source of truth.
- Bash: `set -euo pipefail` at the top, double-quote all variable expansions, prefer `[[ ... ]]` over `[ ... ]`.
- Markdown: prose where possible, lists only when actually a list. No bullet-heavy READMEs.

## Scope

The bot is intentionally narrow. Things that are **in scope**:

- Making the pass-through more reliable
- Improving error messages and operator experience
- Better install/uninstall flows for more distros
- Tests, CI, security hardening

Things that are **out of scope** (better as forks or downstream tools):

- Multi-user support — this bot is single-user by design
- Web UI, API server, Docker orchestration
- Anything that re-implements what Claude Code already does (vault commands, skills, etc.)

## Security

Don't open public issues for security problems — see [SECURITY.md](SECURITY.md).
