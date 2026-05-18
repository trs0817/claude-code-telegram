#!/usr/bin/env bash
#
# claude-code-telegram installer
#
# Wizard-style setup: detects your vault, fetches your chat ID automatically,
# walks you through session mode and response preferences, then deploys and
# starts the systemd service.
#
# Typically invoked by bootstrap.sh (curl | bash), but can be run directly:
#   sudo ./scripts/install.sh
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

# ────────────────────────────────────────────────
# Flags
# ────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

# ────────────────────────────────────────────────
# Constants
# ────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="claude-code-telegram"
INSTALL_DIR="/opt/claude-code-telegram"
SCRIPT_DEST="${INSTALL_DIR}/claude_telegram_bot.py"
UNIT_DEST="/etc/systemd/system/${SERVICE_NAME}.service"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_CYAN=$'\033[36m'

# ────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────
say()    { printf "\n${C_BLUE}▶${C_RESET}  %s\n" "$*"; }
ok()     { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
warn()   { printf "${C_YELLOW}!${C_RESET}  %s\n" "$*"; }
info()   { printf "   ${C_DIM}%s${C_RESET}\n" "$*"; }
die()    { printf "\n${C_RED}✗  %s${C_RESET}\n" "$*" >&2; exit 1; }
header() { printf "\n${C_BOLD}${C_CYAN}%s${C_RESET}\n%s\n" "$*" "$(printf '─%.0s' {1..50})"; }

ask() {
    # All prompts go to /dev/tty so $() captures only the return value.
    local prompt="$1" default="${2:-}" var
    if [[ -n "$default" ]]; then
        printf "   %s ${C_DIM}[%s]${C_RESET}: " "$prompt" "$default" >/dev/tty
        read -r var </dev/tty
        echo "${var:-$default}"
    else
        printf "   %s: " "$prompt" >/dev/tty
        read -r var </dev/tty
        echo "$var"
    fi
}

ask_secret() {
    local prompt="$1" var
    printf "   %s: " "$prompt" >/dev/tty
    read -rsp "" var </dev/tty
    echo >/dev/tty
    echo "$var"
}

pick() {
    # pick <prompt> <option1> <option2> ...
    # All output goes to /dev/tty; only the chosen option string goes to stdout.
    local prompt="$1"; shift
    local options=("$@")
    local default="${options[0]}"
    local i choice

    printf "   %s\n" "$prompt" >/dev/tty
    for i in "${!options[@]}"; do
        local marker=""
        [[ $i -eq 0 ]] && marker=" ${C_DIM}(default)${C_RESET}"
        printf "   ${C_BOLD}%d)${C_RESET} %s%s\n" "$((i+1))" "${options[$i]}" "$marker" >/dev/tty
    done
    printf "   Choice [1]: " >/dev/tty
    read -r choice </dev/tty
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
        echo "${options[$((choice-1))]}"
    else
        warn "Invalid choice, using default: $default" >/dev/tty
        echo "$default"
    fi
}

require_root() {
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "Dry-run mode — skipping root check (no files will be written)"
        return
    fi
    if [[ $EUID -ne 0 ]]; then
        die "This installer must be run as root (use sudo)."
    fi
}

# ────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────
require_root

printf "\n${C_BOLD}${C_CYAN}"
printf "  ╔═══════════════════════════════════════╗\n"
printf "  ║     claude-code-telegram installer    ║\n"
[[ $DRY_RUN -eq 1 ]] && \
printf "  ║          ⚠  DRY RUN — no changes  ⚠   ║\n"
printf "  ╚═══════════════════════════════════════╝\n"
printf "${C_RESET}\n"

say "Checking prerequisites"

# Python 3.9+
if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required but not installed. Install it and re-run."
fi
PY_VER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    die "python3 ${PY_VER} is too old. Need 3.9+."
fi
ok "python3 ${PY_VER}"

# requests library
if ! python3 -c 'import requests' 2>/dev/null; then
    warn "Python 'requests' not installed — installing now..."
    pip3 install requests --break-system-packages 2>/dev/null \
        || pip3 install requests \
        || die "Failed to install 'requests'. Install manually and re-run."
fi
ok "python3 requests"

# claude binary
CLAUDE_BIN_FOUND=$(command -v claude || true)
if [[ -n "$CLAUDE_BIN_FOUND" ]]; then
    ok "claude binary at $CLAUDE_BIN_FOUND"
else
    warn "claude binary not found on PATH. You'll specify the path below."
fi

# systemd
command -v systemctl >/dev/null 2>&1 || die "systemctl not found — systemd is required."
ok "systemd available"

# curl (used for chat ID auto-fetch)
command -v curl >/dev/null 2>&1 && HAS_CURL=1 || HAS_CURL=0

# ────────────────────────────────────────────────
# Step 1 — Service user
# ────────────────────────────────────────────────
header "Step 1 of 7 — Service user"
info "The bot runs as a non-root system user. It must be the same user"
info "whose 'claude' credentials you want the bot to use."
DEFAULT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
SERVICE_USER=$(ask "Service user" "$DEFAULT_USER")
id "$SERVICE_USER" >/dev/null 2>&1 || die "User '$SERVICE_USER' does not exist."
USER_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
ok "Service user: $SERVICE_USER (home: $USER_HOME)"

# ────────────────────────────────────────────────
# Step 2 — Claude binary
# ────────────────────────────────────────────────
header "Step 2 of 7 — Claude binary"
info "Systemd doesn't use your shell PATH, so we need the full path."
CLAUDE_BIN=$(ask "Path to claude binary" "${CLAUDE_BIN_FOUND:-}")
[[ -x "$CLAUDE_BIN" ]] || die "Not executable: $CLAUDE_BIN"
ok "Claude binary: $CLAUDE_BIN"

# Auth check (skipped in dry-run — can't sudo as another user without root)
if [[ $DRY_RUN -eq 0 ]]; then
    if ! sudo -u "$SERVICE_USER" -H test -f "$USER_HOME/.claude/.credentials.json" 2>/dev/null; then
        printf "\n"
        warn "Claude is not authenticated for user '$SERVICE_USER'."
        warn "After install completes, run the following in another terminal:"
        warn "    sudo -u $SERVICE_USER -H $CLAUDE_BIN"
        warn "Complete the auth flow, then restart the service:"
        warn "    sudo systemctl restart $SERVICE_NAME"
        printf "\n"
        read -rp "   Press Enter to continue... "
    else
        ok "Claude credentials found for $SERVICE_USER"
    fi
else
    info "(dry-run) would check: $USER_HOME/.claude/.credentials.json"
fi

# ────────────────────────────────────────────────
# Step 3 — Project directory (vault)
# ────────────────────────────────────────────────
header "Step 3 of 7 — Project directory"
info "This is the working directory for all claude invocations."
info "Typically your Obsidian vault or a code repository."
info ""

# Scan for .obsidian/ folders in common locations
VAULT_CANDIDATES=()
while IFS= read -r -d '' dir; do
    VAULT_CANDIDATES+=("$(dirname "$dir")")
done < <(find "$USER_HOME" -maxdepth 5 -name ".obsidian" -type d -print0 2>/dev/null | head -z -n 5)

for candidate in "$USER_HOME/notes" "$USER_HOME/Notes" "$USER_HOME/Documents/notes"; do
    [[ -d "$candidate" ]] && VAULT_CANDIDATES+=("$candidate")
done

# Deduplicate
readarray -t VAULT_CANDIDATES < <(printf '%s\n' "${VAULT_CANDIDATES[@]}" | sort -u)

VAULT_DEFAULT="$USER_HOME/notes"
if [[ ${#VAULT_CANDIDATES[@]} -eq 1 ]]; then
    VAULT_DEFAULT="${VAULT_CANDIDATES[0]}"
    info "Found vault: $VAULT_DEFAULT"
elif [[ ${#VAULT_CANDIDATES[@]} -gt 1 ]]; then
    info "Found multiple vaults:"
    for i in "${!VAULT_CANDIDATES[@]}"; do
        printf "   ${C_BOLD}%d)${C_RESET} %s\n" "$((i+1))" "${VAULT_CANDIDATES[$i]}"
    done
    printf "   ${C_BOLD}%d)${C_RESET} Enter path manually\n" "$((${#VAULT_CANDIDATES[@]}+1))"
    printf "   Choice [1]: "
    read -r vchoice
    vchoice="${vchoice:-1}"
    if [[ "$vchoice" =~ ^[0-9]+$ ]] && (( vchoice >= 1 && vchoice <= ${#VAULT_CANDIDATES[@]} )); then
        VAULT_DEFAULT="${VAULT_CANDIDATES[$((vchoice-1))]}"
    fi
fi

VAULT_PATH=$(ask "Project directory" "$VAULT_DEFAULT")
[[ -d "$VAULT_PATH" ]] || die "Directory does not exist: $VAULT_PATH"
ok "Project directory: $VAULT_PATH"

# ────────────────────────────────────────────────
# Step 4 — Telegram bot token + chat ID
# ────────────────────────────────────────────────
header "Step 4 of 7 — Telegram credentials"
info "Get your bot token from @BotFather on Telegram."
info ""
BOT_TOKEN=$(ask_secret "Bot token (from @BotFather)")
[[ -n "$BOT_TOKEN" ]] || die "Bot token cannot be empty."
[[ "$BOT_TOKEN" =~ ^[0-9]+: ]] || warn "Token format looks unusual — double-check it."

printf "\n"
info "Your chat ID is the number that identifies your conversation with the bot."
CHAT_ID=""

if [[ $HAS_CURL -eq 1 ]]; then
    printf "   ${C_BOLD}Auto-fetch chat ID?${C_RESET}\n"
    info "Send any message to your bot on Telegram right now, then press Enter."
    info "The installer will call getUpdates to find your ID automatically."
    printf "   (Press Enter when ready, or type your chat ID manually): "
    read -r manual_id

    if [[ -z "$manual_id" ]]; then
        printf "   Fetching from Telegram..."
        TG_RESP=$(curl -s --max-time 10 \
            "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)
        FETCHED_ID=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    results = data.get('result', [])
    if results:
        print(results[-1]['message']['chat']['id'])
except Exception:
    pass
" <<< "$TG_RESP" 2>/dev/null || true)

        if [[ -n "$FETCHED_ID" ]]; then
            printf " ${C_GREEN}found!${C_RESET}\n"
            ok "Chat ID: $FETCHED_ID"
            CHAT_ID="$FETCHED_ID"
        else
            printf " ${C_YELLOW}no messages found.${C_RESET}\n"
            warn "Could not auto-fetch. Make sure you sent a message to your bot first."
        fi
    else
        CHAT_ID="$manual_id"
    fi
fi

if [[ -z "$CHAT_ID" ]]; then
    info "Find your chat ID by visiting:"
    info "  https://api.telegram.org/bot<TOKEN>/getUpdates"
    info "after sending any message to your bot."
    CHAT_ID=$(ask "Telegram chat ID (numeric)")
fi

[[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || die "Chat ID must be a number. Got: $CHAT_ID"
ok "Chat ID: $CHAT_ID"

# ────────────────────────────────────────────────
# Step 5 — Session mode
# ────────────────────────────────────────────────
header "Step 5 of 7 — Conversation memory (session mode)"
info "How should the bot maintain context between your messages?"
info ""

SESSION_MODE_CHOICE=$(pick "Choose session mode:" \
    "threaded — messages continue each other (shares your terminal session)" \
    "dedicated — bot keeps its own isolated session (no bleed with terminal use)" \
    "stateless — each message is a fresh, independent context")

if [[ "$SESSION_MODE_CHOICE" == threaded* ]]; then
    SESSION_MODE="threaded"
    SESSION_ID=""
elif [[ "$SESSION_MODE_CHOICE" == dedicated* ]]; then
    SESSION_MODE="dedicated"
    SESSION_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
    ok "Generated dedicated session ID: $SESSION_ID"
else
    SESSION_MODE="stateless"
    SESSION_ID=""
fi
ok "Session mode: $SESSION_MODE"

# ────────────────────────────────────────────────
# Step 6 — Response format
# ────────────────────────────────────────────────
header "Step 6 of 7 — Response format"
info "How should the bot format claude's replies in Telegram?"
info ""

FMT_CHOICE=$(pick "Choose response format:" \
    "markdown — bold, code blocks, italic rendered by Telegram" \
    "plain — raw text, no formatting (safer if responses contain lots of code)")

if [[ "$FMT_CHOICE" == markdown* ]]; then
    RESPONSE_FORMAT="markdown"
else
    RESPONSE_FORMAT="plain"
fi
ok "Response format: $RESPONSE_FORMAT"

# ────────────────────────────────────────────────
# Step 7 — Typing indicator
# ────────────────────────────────────────────────
header "Step 7 of 7 — Typing indicator"
info "Show animated '...' in Telegram while claude is thinking?"
info ""

TYPING_CHOICE=$(pick "Typing indicator:" \
    "on — show typing animation while claude works" \
    "off — silent until the response arrives")

if [[ "$TYPING_CHOICE" == on* ]]; then
    TYPING_INDICATOR="1"
else
    TYPING_INDICATOR="0"
fi
ok "Typing indicator: $TYPING_CHOICE"

# ────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────
printf "\n${C_BOLD}${C_CYAN}── Summary ─────────────────────────────────────${C_RESET}\n"
printf "   %-22s %s\n" "Service user:"      "$SERVICE_USER"
printf "   %-22s %s\n" "Project directory:" "$VAULT_PATH"
printf "   %-22s %s\n" "Claude binary:"     "$CLAUDE_BIN"
printf "   %-22s %s\n" "Chat ID:"           "$CHAT_ID"
printf "   %-22s %s\n" "Session mode:"      "$SESSION_MODE"
[[ -n "$SESSION_ID" ]] && printf "   %-22s %s\n" "Session ID:" "${SESSION_ID:0:8}...${SESSION_ID: -8}"
printf "   %-22s %s\n" "Response format:"   "$RESPONSE_FORMAT"
printf "   %-22s %s\n" "Typing indicator:"  "$([[ $TYPING_INDICATOR -eq 1 ]] && echo on || echo off)"
printf "${C_BOLD}${C_CYAN}─────────────────────────────────────────────────${C_RESET}\n\n"

if [[ $DRY_RUN -eq 1 ]]; then
    read -rp "   Review output? [Y/n] " confirm
    [[ "${confirm:-y}" =~ ^[Nn]$ ]] && die "Aborted."
else
    read -rp "   Proceed with install? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ────────────────────────────────────────────────
# Install (or dry-run preview)
# ────────────────────────────────────────────────
ENV_FILE="/etc/claude-code-telegram.env"

if [[ $DRY_RUN -eq 1 ]]; then
    printf "\n${C_BOLD}${C_CYAN}── What would be written ────────────────────────${C_RESET}\n\n"

    printf "${C_BOLD}%s${C_RESET}  (0600)\n" "$ENV_FILE"
    printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────"
    cat << EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
VAULT_PATH=${VAULT_PATH}
CLAUDE_BIN=${CLAUDE_BIN}
SESSION_MODE=${SESSION_MODE}
SESSION_ID=${SESSION_ID}
RESPONSE_FORMAT=${RESPONSE_FORMAT}
TYPING_INDICATOR=${TYPING_INDICATOR}
CLAUDE_TIMEOUT=90
MAX_CHUNKS=3
CHUNK_SIZE=3800
POLL_INTERVAL=2
EOF
    printf "\n${C_BOLD}%s${C_RESET}  (0644)\n" "$UNIT_DEST"
    printf "${C_DIM}%s${C_RESET}\n" "--------------------------------------"
    sed \
        -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
        -e "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
        -e "s|__REPLACE_ENV_FILE__|${ENV_FILE}|g" \
        -e "s|__REPLACE_HOME__|${USER_HOME}|g" \
        -e "s|__REPLACE_VAULT_PATH__|${VAULT_PATH}|g" \
        "$REPO_DIR/systemd/${SERVICE_NAME}.service"

    printf "\n${C_BOLD}Commands that would run:${C_RESET}\n"
    printf "   install -d -m 755 %s\n" "$INSTALL_DIR"
    printf "   install -m 644 src/claude_telegram_bot.py %s\n" "$SCRIPT_DEST"
    printf "   systemctl daemon-reload\n"
    printf "   systemctl enable %s\n" "$SERVICE_NAME"
    printf "   systemctl start %s\n" "$SERVICE_NAME"
    printf "\n${C_GREEN}${C_BOLD}  Dry run complete — nothing was written.${C_RESET}\n\n"
    exit 0
fi

say "Installing bot script"
install -d -m 755 "$INSTALL_DIR"
install -m 644 "$REPO_DIR/src/claude_telegram_bot.py" "$SCRIPT_DEST"
ok "Script -> $SCRIPT_DEST"

say "Writing environment file"
cat > "$ENV_FILE" << EOF
# claude-code-telegram environment -- managed by installer
# Edit this file then: sudo systemctl restart $SERVICE_NAME
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
VAULT_PATH=${VAULT_PATH}
CLAUDE_BIN=${CLAUDE_BIN}
SESSION_MODE=${SESSION_MODE}
SESSION_ID=${SESSION_ID}
RESPONSE_FORMAT=${RESPONSE_FORMAT}
TYPING_INDICATOR=${TYPING_INDICATOR}
CLAUDE_TIMEOUT=90
MAX_CHUNKS=3
CHUNK_SIZE=3800
POLL_INTERVAL=2
EOF
chmod 600 "$ENV_FILE"
ok "Env file -> $ENV_FILE (0600)"

say "Writing systemd unit"
sed \
    -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
    -e "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
    -e "s|__REPLACE_ENV_FILE__|${ENV_FILE}|g" \
    -e "s|__REPLACE_HOME__|${USER_HOME}|g" \
    -e "s|__REPLACE_VAULT_PATH__|${VAULT_PATH}|g" \
    "$REPO_DIR/systemd/${SERVICE_NAME}.service" > "$UNIT_DEST"
chmod 644 "$UNIT_DEST"
ok "Unit -> $UNIT_DEST"

say "Enabling and starting service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl start "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "$SERVICE_NAME is running"
    printf "\n${C_GREEN}${C_BOLD}  Installation complete!${C_RESET}\n\n"
    printf "   Tail logs:   ${C_DIM}journalctl -u %s -f${C_RESET}\n" "$SERVICE_NAME"
    printf "   Stop:        ${C_DIM}sudo systemctl stop %s${C_RESET}\n" "$SERVICE_NAME"
    printf "   Uninstall:   ${C_DIM}sudo ./scripts/uninstall.sh${C_RESET}\n"
    printf "\n   You should receive a green online message in Telegram shortly.\n\n"
else
    warn "$SERVICE_NAME failed to start. Recent logs:"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    exit 1
fi
