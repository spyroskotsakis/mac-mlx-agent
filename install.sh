#!/bin/bash
# MLX Server — one-line installer (no Gatekeeper prompt).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/spyroskotsakis/mac-mlx-agent/main/install.sh | bash
#
# Why this works: a *browser* stamps com.apple.quarantine on anything it
# downloads, which is what makes macOS show "Apple could not verify MLXServer is
# free of malware…". `curl` does not stamp that flag, and neither does `ditto`
# when it unzips — so an app installed this way opens cleanly, with no
# `xattr -cr` step.
#
# It always installs the *latest* GitHub release by asking the GitHub API for
# the newest published release, rather than hardcoding a version.

set -euo pipefail

REPO="spyroskotsakis/mac-mlx-agent"
API="https://api.github.com/repos/${REPO}/releases/latest"

echo "==> Finding the latest MLX Server release…"
JSON="$(curl -fsSL "$API")"

TAG="$(printf '%s\n' "$JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | sed -n '1p')"
ZIP_URL="$(printf '%s\n' "$JSON" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' | grep 'releases/download/.*\.zip$' | sed -n '1p')"

if [ -z "$ZIP_URL" ]; then
    echo "error: couldn't find a .zip asset in the latest release." >&2
    exit 1
fi

ZIP="$(basename "$ZIP_URL")"
TMP_ZIP="/tmp/${ZIP}"

echo "==> Downloading MLX Server ${TAG:-latest} (${ZIP})…"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP_ZIP"

# Quit a running copy so it can be replaced cleanly.
if pgrep -x MLXServer >/dev/null 2>&1; then
    echo "==> MLX Server is running — quitting it so it can be replaced…"
    osascript -e 'quit app "MLXServer"' 2>/dev/null || true
    sleep 1
fi

# Admins can write to /Applications directly; otherwise fall back to ~/Applications.
if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    echo "==> No write access to /Applications — installing to ~/Applications."
fi
DEST="$DEST_DIR/MLXServer.app"

if [ -e "$DEST" ]; then
    echo "==> Replacing existing install at ${DEST}…"
    rm -rf "$DEST"
fi

echo "==> Installing to ${DEST_DIR}…"
ditto -x -k "$TMP_ZIP" "$DEST_DIR"
rm -f "$TMP_ZIP"

if [ ! -x "$DEST/Contents/MacOS/MLXServer" ]; then
    echo "error: install looks incomplete (missing ${DEST}/Contents/MacOS/MLXServer)." >&2
    exit 1
fi

echo "==> Done. Launching MLX Server…"
open "$DEST"
echo
echo "MLX Server ${TAG:-latest} is installed at ${DEST}."
echo "Installed via curl, so macOS won't show the Gatekeeper warning."
