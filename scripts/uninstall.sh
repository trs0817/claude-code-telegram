#!/usr/bin/env bash
#
# claude-code-telegram uninstaller
#
# Stops and disables the service, removes the unit file and bot script.
# Does NOT remove your project directory or any data in it.
#
# Usage: sudo ./scripts/uninstall.sh
set -euo pipefail

SERVICE_NAME="claude-code-telegram"
SCRIPT_DEST="/opt/claude-code-telegram/claude_telegram_bot.py"
UNIT_DEST="/etc/systemd/system/${SERVICE_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

read -rp "Uninstall ${SERVICE_NAME}? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME"
fi
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

rm -f "$UNIT_DEST"
rm -rf "$DROPIN_DIR"
rm -f  "$SCRIPT_DEST"
rmdir --ignore-fail-on-non-empty "$(dirname "$SCRIPT_DEST")" 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

echo "✓ Uninstalled. Your project directory was not touched."
