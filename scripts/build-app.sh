#!/bin/bash
# Builds dist/Bannerless.app from source.
# No Apple Developer account needed: the app is ad-hoc signed, which is all
# macOS requires for an app you built yourself.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Bannerless
PLIST=Resources/Info.plist
ICON=(bell.badge.fill 7D6BFF 4B2FC9)

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 1.0)}"
case "$VERSION" in [0-9]*) ;; *) VERSION="1.0";; esac
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "→ Compiling $NAME (release)…"
swift build -c release --product "$NAME"
BIN="$(swift build -c release --show-bin-path)"

APP="dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$PLIST" > "$APP/Contents/Info.plist"

echo "→ Drawing icon…"
TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$TMP/icon.png" "${ICON[@]}"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

echo "→ Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$APP"

(cd dist && rm -f "$NAME.zip" && ditto -c -k --keepParent "$NAME.app" "$NAME.zip")
echo "✓ Built $APP ($VERSION) and dist/$NAME.zip"
