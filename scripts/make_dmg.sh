#!/usr/bin/env bash
# Build a drag-to-Applications DMG from Votelli.app.
#
# Note: a DMG downloaded from the internet is Gatekeeper-quarantined. Because the
# app is self-signed (not notarized), users must right-click -> Open on first
# launch, or run: xattr -dr com.apple.quarantine /Applications/Votelli.app
# Building from source (make install) avoids this entirely.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="Votelli.app"
[[ -d "$APP" ]] || { echo "error: $APP not found. Run 'make app' first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="Votelli-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Votelli" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> built $ROOT/$DMG"
