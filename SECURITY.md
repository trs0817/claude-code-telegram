# Security Policy

## Threat model

The bot's threat model is narrow but worth stating plainly so operators understand what's at stake:

1. **The bot token is equivalent to a remote shell as the service user.** Anyone who obtains the token can DM the bot from any Telegram account *whose chat ID is in the allowlist*. The `TELEGRAM_CHAT_ID` allowlist is the only access gate — there is no second factor.
2. **Claude inherits the file-system permissions of the service user.** A free-form prompt like "delete all my notes" will succeed if the service user can write to the project directory. Scope the service user's permissions to what you're willing to lose to a misbehaving prompt.
3. **The bot communicates with Telegram over HTTPS only.** No on-device crypto; no relay; no peer-to-peer.

## Reporting a vulnerability

If you believe you've found a security issue, please **do not open a public issue**. Instead:

- Email: `security@trsuffern.us` (or open a private security advisory on GitHub if you have access)
- Include: a description, reproduction steps, and an estimate of impact

You can expect:

- An acknowledgement within 7 days
- A fix or mitigation timeline within 30 days for confirmed issues
- Credit in the release notes (unless you prefer to remain anonymous)

## Operator hygiene

- Don't commit `.env`, `config/env`, or the systemd unit file (it embeds the token) to git. The repo's `.gitignore` excludes these paths.
- Rotate the bot token if you suspect leakage: edit the `TELEGRAM_BOT_TOKEN=` line in the unit file, `systemctl daemon-reload && systemctl restart claude-code-telegram`. The old token is invalidated by `@BotFather` issuing a new one.
- Run the service as a non-root user with access scoped to the project directory.
- The unit file installed by `install.sh` is mode `0600`. If you edit it manually, preserve those permissions.
- Watch `journalctl -u claude-code-telegram | grep "Ignored message"` — repeated rejections from unknown chat IDs may indicate someone is probing the token.

## Out of scope

- Multi-user authorization (this bot is single-user by design — fork if you need a different access model)
- Encryption of message contents at rest beyond what Telegram itself provides
- DDoS / rate-limiting Telegram's API (the bot polls; abuse mitigation lives upstream at Telegram)
