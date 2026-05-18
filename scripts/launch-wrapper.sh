#!/usr/bin/env bash
#
# claude-code-telegram launch wrapper (macOS / launchd)
#
# launchd does not support EnvironmentFile the way systemd does.
# This script sources /etc/claude-code-telegram.env and execs the bot,
# keeping credentials out of the plist file.
#
# Installed to /usr/local/bin/claude-code-telegram-launcher by install.sh.
# Do not call directly — managed by launchctl via the LaunchDaemon plist.
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

ENV_FILE="/etc/claude-code-telegram.env"

if [[ ! -f "$ENV_FILE" ]]; then
    printf "claude-code-telegram-launcher: env file not found: %s\n" "$ENV_FILE" >&2
    printf "Re-run the installer to create it.\n" >&2
    exit 1
fi

# Parse and export each variable, stripping comments and trailing whitespace.
# Mirrors the parsing logic in claude-notify for consistency.
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// /}" ]] && continue
    key="${key// /}"
    value="${value%%#*}"
    value="${value%"${value##*[^[:space:]]}"}"
    [[ -n "$key" ]] && export "$key"="$value"
done < "$ENV_FILE"

exec python3 __REPLACE_SCRIPT_PATH__
