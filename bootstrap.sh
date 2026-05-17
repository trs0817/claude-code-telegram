#!/usr/bin/env bash
#
# claude-code-telegram bootstrap — one-line installer entry point
#
# Usage (recommended):
#   curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash
#
# What this does:
#   1. Checks for git and sudo
#   2. Clones the repo to a temp directory
#   3. Re-invokes the full installer (scripts/install.sh) with sudo
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

REPO_URL="https://github.com/trs0817/claude-code-telegram.git"
TMP_DIR=$(mktemp -d /tmp/claude-code-telegram.XXXXXX)

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_BLUE=$'\033[34m'

say() { printf "${C_BLUE}▶${C_RESET}  %s\n" "$*"; }
ok()  { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
die() { printf "${C_RED}✗  %s${C_RESET}\n" "$*" >&2; rm -rf "$TMP_DIR"; exit 1; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

printf "\n${C_BOLD}claude-code-telegram — bootstrap${C_RESET}\n\n"

# Dependency checks
command -v git  >/dev/null 2>&1 || die "git is required. Install it and re-run."
command -v sudo >/dev/null 2>&1 || die "sudo is required."

# Verify sudo works before we get deep
if ! sudo -v 2>/dev/null; then
    die "sudo authentication failed. Re-run as a user with sudo privileges."
fi
ok "sudo available"

say "Cloning repository to $TMP_DIR"
git clone --quiet --depth 1 "$REPO_URL" "$TMP_DIR/repo"
ok "Repository cloned"

say "Handing off to installer"
exec sudo bash "$TMP_DIR/repo/scripts/install.sh" "$@"
