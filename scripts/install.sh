#!/bin/bash
# Installs Bannerless into /Applications, or ~/Applications if that isn't writable.
#
#   From a checkout:   make install
#   A built app:       ./scripts/install.sh dist/Bannerless.app
#   One line:          curl -fsSL https://raw.githubusercontent.com/<you>/bannerless/main/scripts/install.sh | bash
#
# With no argument it builds from source, so it needs Apple's free Command Line
# Tools (xcode-select --install). Nothing here phones home.
set -euo pipefail

APP="${1:-}"
NAME=Bannerless
if [ -z "$APP" ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Bannerless builds from source and needs Apple's free Command Line Tools."
    echo "Run: xcode-select --install   then run this again."
    exit 1
  fi
  if [ -f Package.swift ] && grep -q Bannerless Package.swift; then
    SRC="$(pwd)"
  else
    SRC="$(mktemp -d)/bannerless"
    REPO="${BANNERLESS_REPO:-https://github.com/<you>/bannerless.git}"
    echo "→ Downloading source from $REPO"
    git clone --depth 1 "$REPO" "$SRC"
  fi
  (cd "$SRC" && ./scripts/build-app.sh)
  APP="$SRC/dist/$NAME.app"
fi
NAME="$(basename "$APP" .app)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
# Quit a running copy so the new version is the one that runs.
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -qf "$NAME.app/Contents/MacOS/$NAME$" || break; sleep 1; done
pkill -TERM -f "$NAME.app/Contents/MacOS/$NAME$" 2>/dev/null || true
sleep 1
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
# Built on this Mac, so it was never quarantined; clear the flag in case it was copied in.
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
echo "✓ Installed $DEST/$NAME.app"
open "$DEST/$NAME.app"
