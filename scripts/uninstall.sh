#!/usr/bin/env bash
#
# claude-code-telegram uninstaller
#
# Stops and disables the service, removes the unit file, bot script, and
# claude-notify helper.  Offers to keep the config file so you can reinstall
# later without re-running the wizard.
#
# Usage: sudo ./scripts/uninstall.sh
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

SERVICE_NAME="claude-code-telegram"
RUNTIME_DIR="/opt/claude-code-telegram"
SCRIPT_DEST="${RUNTIME_DIR}/claude_telegram_bot.py"
UNIT_DEST="/etc/systemd/system/${SERVICE_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
ENV_FILE="/etc/claude-code-telegram.env"
NOTIFY_BIN="/usr/local/bin/claude-notify"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'

say()  { printf "${C_BLUE}▶${C_RESET}  %s\n" "$*"; }
ok()   { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!${C_RESET}  %s\n" "$*"; }
die()  { printf "${C_RED}✗  %s${C_RESET}\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo ./scripts/uninstall.sh"

printf "\n${C_BOLD}claude-code-telegram — uninstaller${C_RESET}\n\n"

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
read -rp "Uninstall ${SERVICE_NAME}? [y/N] " confirm </dev/tty
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Stop and disable service
# ---------------------------------------------------------------------------
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    say "Stopping ${SERVICE_NAME}"
    systemctl stop "$SERVICE_NAME"
    ok "Service stopped"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    say "Disabling ${SERVICE_NAME}"
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    ok "Service disabled"
fi

# ---------------------------------------------------------------------------
# Remove unit and drop-in
# ---------------------------------------------------------------------------
if [[ -f "$UNIT_DEST" ]]; then
    rm -f "$UNIT_DEST"
    ok "Removed unit file: $UNIT_DEST"
fi

if [[ -d "$DROPIN_DIR" ]]; then
    rm -rf "$DROPIN_DIR"
    ok "Removed drop-in directory: $DROPIN_DIR"
fi

systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Remove bot script and runtime directory
# ---------------------------------------------------------------------------
if [[ -f "$SCRIPT_DEST" ]]; then
    rm -f "$SCRIPT_DEST"
    ok "Removed bot script: $SCRIPT_DEST"
fi

if [[ -d "$RUNTIME_DIR" ]]; then
    rmdir --ignore-fail-on-non-empty "$RUNTIME_DIR" 2>/dev/null || true
    [[ -d "$RUNTIME_DIR" ]] || ok "Removed runtime directory: $RUNTIME_DIR"
fi

# ---------------------------------------------------------------------------
# Remove claude-notify helper
# ---------------------------------------------------------------------------
if [[ -f "$NOTIFY_BIN" ]]; then
    rm -f "$NOTIFY_BIN"
    ok "Removed claude-notify: $NOTIFY_BIN"
fi

# ---------------------------------------------------------------------------
# Config file — offer to keep it
# ---------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    printf "\n"
    warn "Config file found: ${ENV_FILE}"
    warn "It contains your bot token and chat ID."
    printf "\n"
    read -rp "  Keep config file for a future reinstall? [Y/n] " keep_env </dev/tty
    if [[ "$keep_env" =~ ^[Nn]$ ]]; then
        rm -f "$ENV_FILE"
        ok "Removed config file: $ENV_FILE"
    else
        ok "Config file kept at: $ENV_FILE"
        printf "     To reinstall later without re-running the full wizard:\n"
        printf "     curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | sudo bash\n"
        printf "     The installer will detect the existing config and offer to reuse it.\n"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n${C_GREEN}${C_BOLD}Uninstall complete.${C_RESET}\n"
printf "Your vault / project directory was not touched.\n\n"
