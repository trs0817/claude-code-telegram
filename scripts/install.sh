#!/usr/bin/env bash
#
# claude-code-telegram installer
#
# Supports Linux (systemd) and macOS (launchd).
#
# Usage:
#   sudo ./scripts/install.sh            # normal install
#   sudo ./scripts/install.sh --dry-run  # preview without writing anything
#   sudo ./scripts/install.sh --update   # update an existing install
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=0
UPDATE=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
    [[ "$arg" == "--update"  ]] && UPDATE=1
done

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS_TYPE=$(uname -s)
IS_MACOS=0
[[ "$OS_TYPE" == "Darwin" ]] && IS_MACOS=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_VERSION="v2.0.1"   # ← bump this with every release
SERVICE_NAME="claude-code-telegram"
INSTALL_DIR="/opt/claude-code-telegram"
VERSION_FILE="/usr/local/share/claude-code-telegram/VERSION"
SCRIPT_DEST="${INSTALL_DIR}/claude_telegram_bot.py"
NOTIFY_DEST="/usr/local/bin/claude-notify"
ENV_FILE="/etc/claude-code-telegram.env"
OBSIDIAN_REPO="https://github.com/AgriciDaniel/claude-obsidian"

# Platform-specific service paths
PLIST_LABEL="com.trs0817.claude-code-telegram"
if [[ $IS_MACOS -eq 1 ]]; then
    UNIT_DEST="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
    LAUNCHER_DEST="/usr/local/bin/claude-code-telegram-launcher"
    LOG_FILE="/var/log/claude-code-telegram.log"
else
    UNIT_DEST="/etc/systemd/system/${SERVICE_NAME}.service"
fi

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_CYAN=$'\033[36m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()    { printf "\n${C_BLUE}%s${C_RESET}  %s\n" ">" "$*"; }
ok()     { printf "${C_GREEN}%s${C_RESET}  %s\n" "v" "$*"; }
warn()   { printf "${C_YELLOW}%s${C_RESET}  %s\n" "!" "$*"; }
info()   { printf "   ${C_DIM}%s${C_RESET}\n" "$*"; }
die()    { printf "\n${C_RED}%s  %s${C_RESET}\n" "x" "$*" >&2; exit 1; }
header() {
    printf "\n${C_BOLD}${C_CYAN}%s${C_RESET}\n" "$*"
    printf '%s\n' "$(printf -- '-%.0s' {1..50})"
}

ask() {
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
        warn "Invalid choice, using default." >/dev/tty
        echo "$default"
    fi
}

require_root() {
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "Dry-run mode -- skipping root check (nothing will be written)"
        return
    fi
    [[ $EUID -eq 0 ]] || die "This installer must be run as root (use sudo)."
}

# Cross-platform: get home directory for a user
get_user_home() {
    local user="$1"
    if [[ $IS_MACOS -eq 1 ]]; then
        dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null \
            | awk '{print $2}' \
            || python3 -c "import pwd; print(pwd.getpwnam('${user}').pw_dir)" 2>/dev/null \
            || echo "/Users/${user}"
    else
        getent passwd "$user" | cut -d: -f6
    fi
}

# Service management wrappers (Linux vs macOS)
svc_start() {
    if [[ $IS_MACOS -eq 1 ]]; then
        launchctl load -w "$UNIT_DEST"
    else
        systemctl start "$SERVICE_NAME"
    fi
}

svc_stop() {
    if [[ $IS_MACOS -eq 1 ]]; then
        launchctl unload "$UNIT_DEST" 2>/dev/null || true
    else
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi
}

svc_enable() {
    # launchctl load -w handles enable+start in one step; systemd needs both
    [[ $IS_MACOS -eq 0 ]] && systemctl enable "$SERVICE_NAME" >/dev/null
}

svc_active() {
    if [[ $IS_MACOS -eq 1 ]]; then
        launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"
    else
        systemctl is-active --quiet "$SERVICE_NAME"
    fi
}

svc_daemon_reload() {
    [[ $IS_MACOS -eq 0 ]] && systemctl daemon-reload
}

svc_reset_failed() {
    if [[ $IS_MACOS -eq 0 ]]; then
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    fi
}

svc_log_cmd() {
    if [[ $IS_MACOS -eq 1 ]]; then
        echo "tail -f $LOG_FILE"
    else
        echo "journalctl -u $SERVICE_NAME -f"
    fi
}

svc_recent_logs() {
    if [[ $IS_MACOS -eq 1 ]]; then
        tail -30 "$LOG_FILE" 2>/dev/null || true
    else
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
require_root

PLATFORM_LABEL="Linux (systemd)"
[[ $IS_MACOS -eq 1 ]] && PLATFORM_LABEL="macOS (launchd)"

printf "\n${C_BOLD}${C_CYAN}"
printf "  +---------------------------------------+\n"
printf "  |   claude-code-telegram installer      |\n"
[[ $DRY_RUN -eq 1 ]] && printf "  |        DRY RUN -- no changes           |\n"
[[ $UPDATE  -eq 1 ]] && printf "  |              UPDATE MODE               |\n"
printf "  +---------------------------------------+\n"
printf "${C_RESET}\n"
info "Platform: $PLATFORM_LABEL"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
say "Checking prerequisites"

# Python 3.9+
command -v python3 >/dev/null 2>&1 || die "python3 is required but not installed."
PY_VER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "python3 ${PY_VER} is too old. Need 3.9+."
ok "python3 ${PY_VER}"

# requests
if ! python3 -c 'import requests' 2>/dev/null; then
    warn "Python 'requests' not installed -- installing now..."
    pip3 install requests --break-system-packages 2>/dev/null \
        || pip3 install requests \
        || die "Failed to install 'requests'. Install manually and re-run."
fi
ok "python3 requests"

# Service manager
if [[ $IS_MACOS -eq 1 ]]; then
    command -v launchctl >/dev/null 2>&1 || die "launchctl not found -- is this macOS?"
    ok "launchctl available"
else
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found -- systemd is required."
    ok "systemd available"
fi

# curl (used for chat ID auto-fetch)
command -v curl >/dev/null 2>&1 && HAS_CURL=1 || HAS_CURL=0

# claude binary
CLAUDE_BIN_FOUND=$(command -v claude 2>/dev/null || true)
if [[ -z "$CLAUDE_BIN_FOUND" ]]; then
    printf "\n"
    printf "${C_RED}  x  Claude Code not found on PATH.${C_RESET}\n"
    printf "\n"
    info "Install Claude Code first:"
    info "  https://docs.claude.com/en/docs/claude-code"
    info ""
    info "Then authenticate:"
    info "  claude auth login"
    printf "\n"
    if [[ $DRY_RUN -eq 0 ]]; then
        die "Claude Code must be installed before running this installer."
    else
        warn "Continuing dry-run without claude -- binary check will be skipped."
        CLAUDE_BIN_FOUND=""
    fi
else
    CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1 || echo "unknown")
    ok "Claude Code: $CLAUDE_VERSION at $CLAUDE_BIN_FOUND"
fi

# ---------------------------------------------------------------------------
# Update mode: detect existing install
# ---------------------------------------------------------------------------
EXISTING_INSTALL=0
[[ -f "$ENV_FILE" ]] && EXISTING_INSTALL=1

if [[ $UPDATE -eq 1 ]]; then
    [[ $EXISTING_INSTALL -eq 0 ]] && \
        die "--update specified but no existing install found ($ENV_FILE missing)."
    say "Updating existing install"
    install -d -m 755 "$INSTALL_DIR"
    install -m 644 "$REPO_DIR/src/claude_telegram_bot.py" "$SCRIPT_DEST"
    ok "Bot script updated -> $SCRIPT_DEST"
    install -d -m 755 "$(dirname "$VERSION_FILE")"
    printf "%s\n" "$BOT_VERSION" > "$VERSION_FILE"
    ok "Version file updated -> $VERSION_FILE ($BOT_VERSION)"
    install -m 755 "$REPO_DIR/scripts/claude-notify" "$NOTIFY_DEST"
    ok "claude-notify updated -> $NOTIFY_DEST"
    install -m 755 "$REPO_DIR/scripts/check-update" "/usr/local/bin/check-cct-update"
    ok "check-cct-update updated -> /usr/local/bin/check-cct-update"

    if [[ $IS_MACOS -eq 1 ]]; then
        # Refresh launcher (script path may have changed)
        sed "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
            "$REPO_DIR/scripts/launch-wrapper.sh" > "$LAUNCHER_DEST"
        chmod 755 "$LAUNCHER_DEST"
        ok "Launcher updated -> $LAUNCHER_DEST"
        svc_stop
        svc_start
    else
        systemctl daemon-reload
        systemctl restart "$SERVICE_NAME"
    fi

    sleep 2
    if svc_active; then
        ok "$SERVICE_NAME restarted successfully"
    else
        warn "Service failed to restart. Logs:"
        svc_recent_logs | tail -20
        exit 1
    fi
    printf "\n${C_GREEN}${C_BOLD}  Update complete!${C_RESET}\n\n"
    exit 0
fi

if [[ $EXISTING_INSTALL -eq 1 ]] && [[ $DRY_RUN -eq 0 ]]; then
    printf "\n"
    warn "Existing installation detected ($ENV_FILE)."
    REINSTALL_CHOICE=$(pick "What would you like to do?" \
        "Reinstall -- keep existing config, just redeploy files" \
        "Reconfigure -- walk through all setup steps again" \
        "Cancel")
    case "$REINSTALL_CHOICE" in
        Reinstall*)
            say "Reinstalling with existing config"
            install -d -m 755 "$INSTALL_DIR"
            install -m 644 "$REPO_DIR/src/claude_telegram_bot.py" "$SCRIPT_DEST"
            install -d -m 755 "$(dirname "$VERSION_FILE")"
            printf "%s\n" "$BOT_VERSION" > "$VERSION_FILE"
            install -m 755 "$REPO_DIR/scripts/claude-notify" "$NOTIFY_DEST"
            if [[ $IS_MACOS -eq 1 ]]; then
                sed "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
                    "$REPO_DIR/scripts/launch-wrapper.sh" > "$LAUNCHER_DEST"
                chmod 755 "$LAUNCHER_DEST"
                svc_stop; svc_start
            else
                systemctl daemon-reload
                systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"
            fi
            ok "Reinstalled and restarted."
            exit 0
            ;;
        Cancel*)
            die "Aborted."
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 1 -- Service user
# ---------------------------------------------------------------------------
header "Step 1 of 8 -- Service user"
info "The bot runs as a non-root system user."
info "It must be the same user whose claude credentials you want to use."
DEFAULT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
SERVICE_USER=$(ask "Service user" "$DEFAULT_USER")
id "$SERVICE_USER" >/dev/null 2>&1 || die "User '$SERVICE_USER' does not exist."
USER_HOME=$(get_user_home "$SERVICE_USER")
ok "Service user: $SERVICE_USER (home: $USER_HOME)"

# ---------------------------------------------------------------------------
# Step 2 -- Claude binary
# ---------------------------------------------------------------------------
header "Step 2 of 8 -- Claude Code"
info "The service manager does not use your shell PATH, so we need the full path."
CLAUDE_BIN=$(ask "Path to claude binary" "${CLAUDE_BIN_FOUND:-/usr/local/bin/claude}")
[[ -x "$CLAUDE_BIN" ]] || die "Not executable: $CLAUDE_BIN"

CLAUDE_VER_CHECK=$(sudo -u "$SERVICE_USER" -H "$CLAUDE_BIN" --version 2>/dev/null | head -1 || true)
if [[ -n "$CLAUDE_VER_CHECK" ]]; then
    ok "Claude works for $SERVICE_USER: $CLAUDE_VER_CHECK"
else
    ok "Claude binary confirmed executable: $CLAUDE_BIN"
fi

# Auth check
if [[ $DRY_RUN -eq 0 ]]; then
    if sudo -u "$SERVICE_USER" -H test -f "$USER_HOME/.claude/.credentials.json" 2>/dev/null; then
        ok "Claude credentials found for $SERVICE_USER"
    else
        printf "\n"
        warn "Claude is not authenticated for '$SERVICE_USER'."
        warn "You have two options:"
        info ""
        info "Option A -- Browser auth:"
        info "  Open another terminal and run:"
        info "    sudo -u $SERVICE_USER -H $CLAUDE_BIN auth login"
        info ""
        info "Option B -- API key (recommended for headless servers):"
        info "  Add to $ENV_FILE after install:"
        info "    ANTHROPIC_API_KEY=sk-ant-..."
        info "  Get a key at: https://console.anthropic.com"
        printf "\n"
        read -rp "   Press Enter to continue (you can authenticate after install)... " </dev/tty
    fi
else
    info "(dry-run) would check: $USER_HOME/.claude/.credentials.json"
fi

# ---------------------------------------------------------------------------
# Step 3 -- Project directory (vault)
# ---------------------------------------------------------------------------
header "Step 3 of 8 -- Project directory"
info "This is the working directory for all claude invocations."
info "Typically your Obsidian vault or a code repository."
info ""

# Scan for .obsidian/ folders
VAULT_CANDIDATES=()
while IFS= read -r -d '' dir; do
    VAULT_CANDIDATES+=("$(dirname "$dir")")
done < <(find "$USER_HOME" -maxdepth 5 -name ".obsidian" -type d -print0 2>/dev/null | head -z -n 5)

for candidate in "$USER_HOME/notes" "$USER_HOME/Notes" "$USER_HOME/Documents/notes"; do
    [[ -d "$candidate" ]] && VAULT_CANDIDATES+=("$candidate")
done

readarray -t VAULT_CANDIDATES < <(printf '%s\n' "${VAULT_CANDIDATES[@]}" | sort -u 2>/dev/null || true)

VAULT_DEFAULT="$USER_HOME/notes"
if [[ ${#VAULT_CANDIDATES[@]} -eq 1 ]]; then
    VAULT_DEFAULT="${VAULT_CANDIDATES[0]}"
    info "Found vault: $VAULT_DEFAULT"
elif [[ ${#VAULT_CANDIDATES[@]} -gt 1 ]]; then
    info "Found multiple candidates:"
    for i in "${!VAULT_CANDIDATES[@]}"; do
        printf "   ${C_BOLD}%d)${C_RESET} %s\n" "$((i+1))" "${VAULT_CANDIDATES[$i]}" >/dev/tty
    done
    printf "   ${C_BOLD}%d)${C_RESET} Enter path manually\n" "$((${#VAULT_CANDIDATES[@]}+1))" >/dev/tty
    printf "   Choice [1]: " >/dev/tty
    read -r vchoice </dev/tty
    vchoice="${vchoice:-1}"
    if [[ "$vchoice" =~ ^[0-9]+$ ]] && (( vchoice >= 1 && vchoice <= ${#VAULT_CANDIDATES[@]} )); then
        VAULT_DEFAULT="${VAULT_CANDIDATES[$((vchoice-1))]}"
    fi
fi

VAULT_PATH=$(ask "Project directory" "$VAULT_DEFAULT")
[[ -d "$VAULT_PATH" ]] || die "Directory does not exist: $VAULT_PATH"
ok "Project directory: $VAULT_PATH"

if [[ ! -d "$VAULT_PATH/.obsidian" ]]; then
    printf "\n"
    info "Tip: For the best experience, use an Obsidian vault with Claude skills."
    info "  $OBSIDIAN_REPO"
    info "You can change VAULT_PATH anytime by editing $ENV_FILE"
    printf "\n"
fi

# ---------------------------------------------------------------------------
# Step 4 -- Telegram credentials
# ---------------------------------------------------------------------------
header "Step 4 of 8 -- Telegram credentials"
info "Get your bot token from @BotFather on Telegram."
info ""

BOT_TOKEN=""
while [[ -z "$BOT_TOKEN" ]]; do
    BOT_TOKEN=$(ask_secret "Bot token (from @BotFather)")
    [[ -z "$BOT_TOKEN" ]] && warn "Token cannot be empty -- try again." >/dev/tty
done
[[ "$BOT_TOKEN" =~ ^[0-9]+: ]] || warn "Token format looks unusual -- double-check it."

# Chat ID auto-fetch
printf "\n" >/dev/tty
info "Your chat ID identifies your conversation with the bot."
CHAT_ID=""

if [[ $HAS_CURL -eq 1 ]]; then
    printf "   ${C_BOLD}Auto-fetch chat ID${C_RESET}\n" >/dev/tty
    info "Send any message to your bot on Telegram now, then press Enter."
    info "Or type your chat ID manually and press Enter."
    printf "   (Enter to auto-fetch, or type ID): " >/dev/tty
    read -r manual_id </dev/tty

    if [[ -z "$manual_id" ]]; then
        printf "   Waiting a moment for Telegram to register your message..." >/dev/tty
        sleep 2

        FETCHED_ID=""
        for _attempt in 1 2 3; do
            TG_RESP=$(curl -s --max-time 10 \
                "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)

            FETCHED_ID=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    if not data.get('ok'):
        sys.stderr.write('API error: ' + str(data.get('description', data)) + '\n')
        sys.exit(1)
    for upd in reversed(data.get('result', [])):
        for key in ('message', 'channel_post', 'edited_message', 'edited_channel_post', 'my_chat_member'):
            obj = upd.get(key, {})
            chat_id = obj.get('chat', {}).get('id') if obj else None
            if chat_id is not None:
                print(chat_id)
                sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e) + '\n')
" <<< "$TG_RESP" 2>/dev/tty || true)

            if [[ -n "$FETCHED_ID" ]]; then
                break
            fi
            [[ $_attempt -lt 3 ]] && sleep 2
        done

        if [[ -n "$FETCHED_ID" ]]; then
            printf " found!\n" >/dev/tty
            ok "Chat ID: $FETCHED_ID"
            CHAT_ID="$FETCHED_ID"
        else
            printf "\n" >/dev/tty
            warn "Auto-fetch came back empty after 3 tries."
            info "Common reasons:"
            info "  1. The message was sent before the bot token was set up"
            info "  2. The old bot already consumed the update -- send another message"
            info "  3. Wrong bot token"
            info ""
            info "Find your ID manually: https://api.telegram.org/bot${BOT_TOKEN}/getUpdates"
        fi
    else
        CHAT_ID="$manual_id"
    fi
fi

while [[ -z "$CHAT_ID" ]] || ! [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]]; do
    [[ -n "$CHAT_ID" ]] && warn "Must be a number -- try again." >/dev/tty
    info "Find it at: https://api.telegram.org/bot<TOKEN>/getUpdates"
    CHAT_ID=$(ask "Telegram chat ID (numeric)")
done
ok "Chat ID: $CHAT_ID"

printf "\n"
info "You can allow additional users to use the bot (comma-separated chat IDs)."
info "Leave blank for single-user (just you)."
EXTRA_USERS=$(ask "Additional allowed user IDs" "")
if [[ -n "$EXTRA_USERS" ]]; then
    ALLOWED_USERS="${CHAT_ID},${EXTRA_USERS}"
else
    ALLOWED_USERS="$CHAT_ID"
fi
ok "Allowed users: $ALLOWED_USERS"

# ---------------------------------------------------------------------------
# Step 5 -- Session mode
# ---------------------------------------------------------------------------
header "Step 5 of 8 -- Conversation memory"
info "How should the bot maintain context between your messages?"
info ""

SESSION_MODE_CHOICE=$(pick "Choose session mode:" \
    "threaded -- messages continue each other (shares your terminal session)" \
    "dedicated -- bot keeps its own isolated session (no bleed with terminal)" \
    "stateless -- each message is a fresh independent context")

if [[ "$SESSION_MODE_CHOICE" == threaded* ]]; then
    SESSION_MODE="threaded"; SESSION_ID=""
elif [[ "$SESSION_MODE_CHOICE" == dedicated* ]]; then
    SESSION_MODE="dedicated"
    SESSION_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
    ok "Generated dedicated session ID: ${SESSION_ID:0:8}..."
else
    SESSION_MODE="stateless"; SESSION_ID=""
fi
ok "Session mode: $SESSION_MODE"

# ---------------------------------------------------------------------------
# Step 6 -- Permission mode
# ---------------------------------------------------------------------------
header "Step 6 of 8 -- Permission mode"
info "How should claude handle tool use (bash commands, file writes, etc.)?"
info ""

PERM_CHOICE=$(pick "Choose permission mode:" \
    "safe -- file edits auto-approved; shows plan for review (recommended)" \
    "unrestricted -- all operations auto-approved with /dangerously-skip-permissions")

if [[ "$PERM_CHOICE" == safe* ]]; then
    PERMISSION_MODE="safe"
else
    PERMISSION_MODE="unrestricted"
    printf "\n"
    warn "Unrestricted mode: Claude will show its plan before executing."
    info "Send /trust to skip the plan step for a session."
    info "Only use this mode on a server you control with a private bot token."
fi
ok "Permission mode: $PERMISSION_MODE"

# ---------------------------------------------------------------------------
# Step 7 -- Response format
# ---------------------------------------------------------------------------
header "Step 7 of 8 -- Response format"
info ""

FMT_CHOICE=$(pick "Choose response format:" \
    "markdown -- bold, code blocks, italic rendered by Telegram (recommended)" \
    "plain -- raw text, no formatting")

RESPONSE_FORMAT="markdown"
[[ "$FMT_CHOICE" == plain* ]] && RESPONSE_FORMAT="plain"
ok "Response format: $RESPONSE_FORMAT"

# ---------------------------------------------------------------------------
# Step 8 -- Typing indicator
# ---------------------------------------------------------------------------
header "Step 8 of 8 -- Typing indicator"
info ""

TYPING_CHOICE=$(pick "Show typing animation while Claude thinks?" \
    "on -- show animated dots while Claude works (recommended)" \
    "off -- silent until response arrives")

TYPING_INDICATOR="1"
[[ "$TYPING_CHOICE" == off* ]] && TYPING_INDICATOR="0"
ok "Typing indicator: $TYPING_CHOICE"

# ---------------------------------------------------------------------------
# Test invocation
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]] && [[ -n "$CLAUDE_BIN_FOUND" ]]; then
    say "Testing Claude invocation"
    info "Running a quick test in $VAULT_PATH ..."
    TEST_OUT=$(sudo -u "$SERVICE_USER" -H \
        "$CLAUDE_BIN" --permission-mode acceptEdits -p "Reply with only the word: OK" \
        --no-session-persistence 2>/dev/null \
        | tr -d '\n' | head -c 20 || true)
    if echo "$TEST_OUT" | grep -qi "ok"; then
        ok "Claude responded correctly"
    else
        warn "Unexpected test response: '${TEST_OUT}'"
        warn "Claude may not be authenticated. The service will start, but"
        warn "commands may fail until auth is complete."
        read -rp "   Continue anyway? [y/N] " cont </dev/tty
        [[ "${cont:-n}" =~ ^[Yy]$ ]] || die "Aborted."
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n${C_BOLD}${C_CYAN}-- Summary $(printf -- '-%.0s' {1..38})${C_RESET}\n"
printf "   %-22s %s\n" "Platform:"          "$PLATFORM_LABEL"
printf "   %-22s %s\n" "Service user:"      "$SERVICE_USER"
printf "   %-22s %s\n" "Project directory:" "$VAULT_PATH"
printf "   %-22s %s\n" "Claude binary:"     "$CLAUDE_BIN"
printf "   %-22s %s\n" "Allowed users:"     "$ALLOWED_USERS"
printf "   %-22s %s\n" "Session mode:"      "$SESSION_MODE"
[[ -n "$SESSION_ID" ]] && printf "   %-22s %s\n" "Session ID:" "${SESSION_ID:0:8}...${SESSION_ID: -8}"
printf "   %-22s %s\n" "Permission mode:"   "$PERMISSION_MODE"
printf "   %-22s %s\n" "Response format:"   "$RESPONSE_FORMAT"
printf "   %-22s %s\n" "Typing indicator:"  "$([[ $TYPING_INDICATOR -eq 1 ]] && echo on || echo off)"
printf "${C_BOLD}${C_CYAN}$(printf -- '-%.0s' {1..50})${C_RESET}\n\n"

if [[ $DRY_RUN -eq 1 ]]; then
    read -rp "   Review generated files? [Y/n] " confirm </dev/tty
    [[ "${confirm:-y}" =~ ^[Nn]$ ]] && die "Aborted."
else
    read -rp "   Proceed with install? [y/N] " confirm </dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ---------------------------------------------------------------------------
# Dry-run preview
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
    printf "\n${C_BOLD}${C_CYAN}-- Generated: %s${C_RESET}\n" "$ENV_FILE"
    printf '%s\n' "$(printf -- '-%.0s' {1..50})"
    cat <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
ALLOWED_USERS=${ALLOWED_USERS}
VAULT_PATH=${VAULT_PATH}
CLAUDE_BIN=${CLAUDE_BIN}
SESSION_MODE=${SESSION_MODE}
SESSION_ID=${SESSION_ID}
PERMISSION_MODE=${PERMISSION_MODE}
RESPONSE_FORMAT=${RESPONSE_FORMAT}
TYPING_INDICATOR=${TYPING_INDICATOR}
CLAUDE_TIMEOUT=90
MAX_CHUNKS=3
CHUNK_SIZE=3800
POLL_INTERVAL=2
EOF
    printf "\n${C_BOLD}${C_CYAN}-- Generated: %s${C_RESET}\n" "$UNIT_DEST"
    printf '%s\n' "$(printf -- '-%.0s' {1..50})"
    if [[ $IS_MACOS -eq 1 ]]; then
        sed \
            -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
            -e "s|__REPLACE_LAUNCHER__|${LAUNCHER_DEST}|g" \
            "$REPO_DIR/launchd/com.trs0817.claude-code-telegram.plist"
        printf "\n${C_BOLD}${C_CYAN}-- Generated: %s${C_RESET}\n" "$LAUNCHER_DEST"
        printf '%s\n' "$(printf -- '-%.0s' {1..50})"
        sed "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
            "$REPO_DIR/scripts/launch-wrapper.sh"
    else
        sed \
            -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
            -e "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
            -e "s|__REPLACE_ENV_FILE__|${ENV_FILE}|g" \
            -e "s|__REPLACE_HOME__|${USER_HOME}|g" \
            -e "s|__REPLACE_VAULT_PATH__|${VAULT_PATH}|g" \
            "$REPO_DIR/systemd/${SERVICE_NAME}.service"
    fi
    printf "\n${C_BOLD}Commands that would run:${C_RESET}\n"
    printf "   install -d -m 755 %s\n" "$INSTALL_DIR"
    printf "   install -m 644 src/claude_telegram_bot.py %s\n" "$SCRIPT_DEST"
    printf "   install -m 755 scripts/claude-notify %s\n" "$NOTIFY_DEST"
    if [[ $IS_MACOS -eq 1 ]]; then
        printf "   install launcher -> %s\n" "$LAUNCHER_DEST"
        printf "   launchctl load -w %s\n" "$UNIT_DEST"
    else
        printf "   systemctl daemon-reload && enable && start %s\n" "$SERVICE_NAME"
    fi
    printf "\n${C_GREEN}${C_BOLD}  Dry run complete -- nothing was written.${C_RESET}\n\n"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------
say "Installing files"
install -d -m 755 "$INSTALL_DIR"
install -m 644 "$REPO_DIR/src/claude_telegram_bot.py" "$SCRIPT_DEST"
ok "Bot script -> $SCRIPT_DEST"

install -d -m 755 "$(dirname "$VERSION_FILE")"
printf "%s\n" "$BOT_VERSION" > "$VERSION_FILE"
ok "Version file -> $VERSION_FILE ($BOT_VERSION)"

install -m 755 "$REPO_DIR/scripts/claude-notify" "$NOTIFY_DEST"
ok "claude-notify -> $NOTIFY_DEST"

install -m 755 "$REPO_DIR/scripts/check-update" "/usr/local/bin/check-cct-update"
ok "check-cct-update -> /usr/local/bin/check-cct-update"

# Weekly update check cron (Linux only; macOS can use launchd but cron works too)
if [[ $IS_MACOS -eq 0 ]]; then
    printf "0 9 * * 1 root /usr/local/bin/check-cct-update\n" \
        > /etc/cron.d/claude-code-telegram-update
    chmod 644 /etc/cron.d/claude-code-telegram-update
    ok "Weekly update check cron -> /etc/cron.d/claude-code-telegram-update"
fi

if [[ $IS_MACOS -eq 1 ]]; then
    sed "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
        "$REPO_DIR/scripts/launch-wrapper.sh" > "$LAUNCHER_DEST"
    chmod 755 "$LAUNCHER_DEST"
    ok "Launcher -> $LAUNCHER_DEST"
fi

# ---------------------------------------------------------------------------
# Write environment file
# ---------------------------------------------------------------------------
say "Writing environment file"
cat > "$ENV_FILE" <<EOF
# claude-code-telegram environment -- managed by installer
# Edit then restart: $(if [[ $IS_MACOS -eq 1 ]]; then echo "sudo launchctl unload $UNIT_DEST && sudo launchctl load -w $UNIT_DEST"; else echo "sudo systemctl restart $SERVICE_NAME"; fi)
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
ALLOWED_USERS=${ALLOWED_USERS}
VAULT_PATH=${VAULT_PATH}
CLAUDE_BIN=${CLAUDE_BIN}
SESSION_MODE=${SESSION_MODE}
SESSION_ID=${SESSION_ID}
PERMISSION_MODE=${PERMISSION_MODE}
RESPONSE_FORMAT=${RESPONSE_FORMAT}
TYPING_INDICATOR=${TYPING_INDICATOR}
CLAUDE_TIMEOUT=90
MAX_CHUNKS=3
CHUNK_SIZE=3800
POLL_INTERVAL=2
EOF
chmod 600 "$ENV_FILE"
ok "Env file -> $ENV_FILE (0600)"

# ---------------------------------------------------------------------------
# Write and start service
# ---------------------------------------------------------------------------
say "Writing service definition"
if [[ $IS_MACOS -eq 1 ]]; then
    sed \
        -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
        -e "s|__REPLACE_LAUNCHER__|${LAUNCHER_DEST}|g" \
        "$REPO_DIR/launchd/com.trs0817.claude-code-telegram.plist" > "$UNIT_DEST"
    chmod 644 "$UNIT_DEST"
    ok "LaunchDaemon plist -> $UNIT_DEST"
else
    sed \
        -e "s|__REPLACE_USER__|${SERVICE_USER}|g" \
        -e "s|__REPLACE_SCRIPT_PATH__|${SCRIPT_DEST}|g" \
        -e "s|__REPLACE_ENV_FILE__|${ENV_FILE}|g" \
        -e "s|__REPLACE_HOME__|${USER_HOME}|g" \
        -e "s|__REPLACE_VAULT_PATH__|${VAULT_PATH}|g" \
        "$REPO_DIR/systemd/${SERVICE_NAME}.service" > "$UNIT_DEST"
    chmod 644 "$UNIT_DEST"
    ok "Unit -> $UNIT_DEST"
fi

say "Enabling and starting service"
svc_daemon_reload
svc_enable
svc_start

sleep 2
LOG_CMD=$(svc_log_cmd)
if [[ $IS_MACOS -eq 1 ]]; then
    STOP_CMD="launchctl unload $UNIT_DEST"
else
    STOP_CMD="systemctl stop $SERVICE_NAME"
fi
if svc_active; then
    ok "$SERVICE_NAME is running"
    printf "\n${C_GREEN}${C_BOLD}  Installation comp