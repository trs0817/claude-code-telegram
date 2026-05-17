# Manual installation

If you'd rather not run [`scripts/install.sh`](../scripts/install.sh), this is what it does, broken into steps you can run by hand.

## Prerequisites

- Linux with systemd
- Python 3.9 or newer
- `python3 -c "import requests"` succeeds (otherwise `pip install requests`, possibly with `--break-system-packages` on Debian 12+)
- Claude Code installed and **authenticated as the user that will run the service**. Confirm with `ls ~/.claude/.credentials.json`; if it doesn't exist, run `claude` interactively once.
- A project directory the bot will operate in (vault, code repo, etc.)
- Bot token from `@BotFather` and your numeric chat ID (see [README](../README.md#getting-a-bot-token-and-chat-id))

## Steps

```bash
# 1. Clone and install the bot script to /opt
sudo install -d -m 755 /opt/claude-code-telegram
sudo install -m 644 src/claude_telegram_bot.py /opt/claude-code-telegram/

# 2. Write the systemd unit, substituting your values.
#    Use `read -rs` so the token isn't echoed or stored in shell history.
read -rsp "Bot token: " BOT_TOKEN; echo
sudo tee /etc/systemd/system/claude-code-telegram.service >/dev/null <<EOF
[Unit]
Description=claude-code-telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME
Environment=TELEGRAM_BOT_TOKEN=$BOT_TOKEN
Environment=TELEGRAM_CHAT_ID=YOUR_NUMERIC_CHAT_ID
Environment=VAULT_PATH=/path/to/your/project
Environment=CLAUDE_BIN=/usr/bin/claude
Environment=CLAUDE_CONTINUE=1
Environment=CLAUDE_TIMEOUT=90
ExecStart=/usr/bin/python3 /opt/claude-code-telegram/claude_telegram_bot.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
unset BOT_TOKEN
sudo chmod 600 /etc/systemd/system/claude-code-telegram.service

# 3. Verify the unit parses
sudo systemd-analyze verify /etc/systemd/system/claude-code-telegram.service

# 4. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable claude-code-telegram
sudo systemctl start claude-code-telegram

# 5. Watch logs
journalctl -u claude-code-telegram -f
```

You should receive a `🟢 online` message in Telegram within a few seconds. Send `/help` to confirm the bot is responding.

## Pre-flight smoke test

Before enabling, you can validate your config without starting the poller:

```bash
sudo -u YOUR_USERNAME \
  TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... VAULT_PATH=... \
  python3 /opt/claude-code-telegram/claude_telegram_bot.py --check
```

If it prints `Config OK`, the unit will start cleanly.

## Optional: OnFailure alerting

If you already have a `notify-failure@.service` template on the system (from a separate alerting stack), you can wire crashes to that template:

```bash
sudo install -d /etc/systemd/system/claude-code-telegram.service.d
sudo install -m 644 systemd/notify-on-fail.conf.example \
    /etc/systemd/system/claude-code-telegram.service.d/notify-on-fail.conf
sudo systemctl daemon-reload
```

The bot's own restart-on-failure handles transient crashes; the OnFailure hook is for when restart doesn't help — at which point you want a different channel to tell you about it.

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```

This stops/disables the service and removes `/etc/systemd/system/claude-code-telegram.service` and `/opt/claude-code-telegram/`. Your project directory is untouched.
