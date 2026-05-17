# Troubleshooting

When something goes wrong, this is the order to check things.

## 1. Is the service even running?

```bash
sudo systemctl status claude-code-telegram
journalctl -u claude-code-telegram -n 50 --no-pager
```

If `Active: failed` or `Active: activating (auto-restart)`, the bot is crashing on startup. Read the journal — `validate_config()` prints a clear list of missing or invalid env vars.

## 2. Bot is "active" but doesn't reply

| Likely cause | Quick check | Fix |
|---|---|---|
| Wrong chat ID | `journalctl -u claude-code-telegram \| grep "Ignored message"` | Update `TELEGRAM_CHAT_ID=` in the unit and `systemctl restart` |
| Telegram polling conflict | `journalctl -u claude-code-telegram \| grep -i conflict` | Stop the other poller (manual `python3 claude_telegram_bot.py` in another shell, or a duplicate service) |
| Network egress blocked | `curl -sS https://api.telegram.org` from the host | Check firewall / DNS |

## 3. Bot replies with `❌ Claude binary not found`

```bash
which claude
```

If empty, Claude Code isn't installed for the **service user** — install it. If it returns a path, update `CLAUDE_BIN=` in the unit to that exact path and restart.

## 4. Bot replies with auth errors to every prompt

The service user has not authenticated Claude. SSH in as that user and run `claude` interactively once. Then:

```bash
sudo systemctl restart claude-code-telegram
```

This is the most common silent failure during first-time setup — the bot starts fine, but every claude invocation fails because there's no `~/.claude/.credentials.json`.

## 5. Bot replies with `⏱ Claude timed out after 90s`

The prompt either kicked off something heavy (large vault scan, long-running tool call) or claude itself is stuck. Options:

- Increase `CLAUDE_TIMEOUT=` (try 180 or 300) and `systemctl restart`
- Break the request into smaller prompts
- Check `htop` or `top` on the server to see if claude is actually working

## 6. Slash commands behave wrong

The bot only intercepts `/help`, `/more`, `/start`. Everything else, including `/save` and `/lint`, is forwarded to `claude -p` verbatim. If `/save` isn't doing what you expect:

```bash
ls /path/to/your/vault/.claude/commands/
```

Your vault needs a `save.md` (or whatever command) for claude to know what `/save` means. If the directory is empty, your slash commands don't exist yet — define them server-side in your vault, not in this bot.

## 7. `--continue` is picking up the wrong session

If you run `claude` directly in the project dir (terminal SSH session, IDE, etc.), the bot's next `--continue` will resume *that* session. Confusing if unintended.

Workarounds:

- Set `CLAUDE_CONTINUE=0` in the unit and restart — each Telegram message becomes stateless. You lose conversation continuity but gain isolation.
- Or: keep `--continue` and embrace the cross-device threading — your terminal and your phone become two windows into the same conversation.

## 8. Service file changed but bot still acts old

```bash
sudo systemctl daemon-reload
sudo systemctl restart claude-code-telegram
```

`daemon-reload` is required after any change to the unit file. Without it, systemd keeps using the old version.

## 9. Logs are noisy / want to filter

```bash
# Just the bot's own log lines
journalctl -u claude-code-telegram --since "10 min ago"

# Just received messages
journalctl -u claude-code-telegram | grep "Received:"

# Just claude invocations
journalctl -u claude-code-telegram | grep "Running Claude"

# Live tail
journalctl -u claude-code-telegram -f
```

## 10. Bot token suspected leaked

Rotate immediately:

1. DM `@BotFather`, `/revoke`, select the bot — this invalidates the old token and issues a new one
2. Edit `Environment=TELEGRAM_BOT_TOKEN=...` in `/etc/systemd/system/claude-code-telegram.service`
3. `sudo systemctl daemon-reload && sudo systemctl restart claude-code-telegram`

The unit file's `0600` permissions help — but if it ended up in git or a backup, assume the token is compromised and rotate.

## Still stuck?

Open a [bug report](https://github.com/trs0817/claude-code-telegram/issues/new?template=bug_report.md) with the output of `journalctl -u claude-code-telegram -n 50 --no-pager` (redacting the token if it appears).
