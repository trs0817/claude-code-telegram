#!/usr/bin/env bash
#
# claude-code-telegram bootstrap — one-line installer entry point
#
# Usage (recommended):
#   curl -sSL https://raw.githubusercontent.com/trs0817/claude-code-telegram/main/bootstrap.sh | bash
#
# Security note: piping a remote script to bash is inherently trusting the source.
# This bootstrap mitigates risk by:
#   1. Cloning a pinned release tag (RELEASE_TAG) rather than an unversioned branch
#   2. Optionally verifying the cloned commit hash against EXPECTED_COMMIT
#
# To install a different version: RELEASE_TAG=v2.0.1 bash bootstrap.sh
# To skip version pinning (HEAD of main): RELEASE_TAG=main bash bootstrap.sh
#
# What this does:
#   1. Checks for git and sudo
#   2. Clones the pinned release tag to a temp directory
#   3. Verifies the commit hash (if EXPECTED_COMMIT is set)
#   4. Re-invokes the full installer (scripts/install.sh) with sudo
#
# Repository: https://github.com/trs0817/claude-code-telegram
# License: MIT

set -euo pipefail

REPO_URL="https://github.com/trs0817/claude-code-telegram.git"
# Pin to a specific release tag so curl|bash always installs a known-good version.
# Bump both values on every release.
RELEASE_TAG="${RELEASE_TAG:-v2.1.0}"
# Optional: set to the expected commit SHA for stronger integrity verification.
# Leave empty to skip the hash check (tag verification is still performed).
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"

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

say "Cloning $RELEASE_TAG to $TMP_DIR"
git clone --quiet --depth 1 --branch "$RELEASE_TAG" "$REPO_URL" "$TMP_DIR/repo"
ok "Repository cloned (tag: $RELEASE_TAG)"

# --- Integrity verification -----------------------------------------------
ACTUAL_COMMIT=$(git -C "$TMP_DIR/repo" rev-parse HEAD)
ok "Commit: ${ACTUAL_COMMIT:0:12}"

if [[ -n "$EXPECTED_COMMIT" ]]; then
    if [[ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]]; then
        die "Commit hash mismatch! Expected $EXPECTED_COMMIT, got $ACTUAL_COMMIT. Aborting."
    fi
    ok "Commit hash verified"
fi
# --------------------------------------------------------------------------

say "Handing off to installer"
exec sudo bash "$TMP_DIR/repo/scripts/install.sh" "$@"
