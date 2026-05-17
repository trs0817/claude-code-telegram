---
name: Bug report
about: Something doesn't work the way the README says it should
title: "[bug] "
labels: bug
assignees: ''
---

## What happened

A clear description of the bug. What did you send the bot, and what did it reply (or not reply)?

## Expected behavior

What did you expect to happen instead?

## Reproduction

Minimal steps to reproduce. If you can trigger this from a single prompt, paste the prompt.

## Environment

- OS / distro:
- `python3 --version`:
- `claude --version`:
- `systemctl --version | head -1`:
- claude-code-telegram version (`/help` in Telegram shows it):
- Installed via `install.sh` or manual?

## Logs

```
# paste output of: journalctl -u claude-code-telegram -n 50 --no-pager
# REDACT the bot token if it appears
```

## Additional context

Anything else — recent changes, network conditions, related issues, etc.
