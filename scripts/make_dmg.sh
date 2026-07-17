#!/usr/bin/env bash
# Build a drag-to-Applications DMG from Votelli.app, then notarize and staple it.
#
# The app must already be release-signed (Developer ID + hardened runtime + secure
# timestamp) — `make dmg` handles that. Notarization uploads the DMG to Apple and
# blocks for a few minutes; stapling then attaches the ticket so the DMG passes
# Gatekeeper even on a machine that's offline. Set NOTARIZE=0 to build an
# unnotarized DMG for local testing (never for a release).
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-votelli-notary}"

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

if [[ "${NOTARIZE:-1}" != "1" ]]; then
    echo "==> skipping notarization (NOTARIZE=$NOTARIZE) — do not ship this DMG"
    exit 0
fi

if [[ -z "${EXPECTED_LEAF_HASH:-}" ]]; then
    echo "error: notarization requires the release signing identity, but EXPECTED_LEAF_HASH" >&2
    echo "       is unset. Run 'make dmg', which sets it from RELEASE_LEAF_HASH." >&2
    exit 1
fi

# Sign the disk image itself with the same Developer ID identity that signed the
# app. Gatekeeper assesses the DMG's own signature when the user opens a download,
# so an unsigned image is rejected ("no usable signature") even once it's notarized
# and stapled. Sign before submitting: notarization covers the signed image.
echo "==> code signing $DMG"
codesign --force --sign "$EXPECTED_LEAF_HASH" --timestamp "$DMG"

# Submit to Apple and wait. --wait blocks until the submission reaches a terminal
# state (typically a few minutes), so the rest of this script can assume a verdict.
echo "==> notarizing (this takes a few minutes)"
SUBMIT_LOG="$(mktemp)"
trap 'rm -rf "$STAGE" "$SUBMIT_LOG"' EXIT
set +e
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$SUBMIT_LOG"
NOTARY_RC="${PIPESTATUS[0]}"
set -e

SUBMISSION_ID="$(grep -m1 -Eo '  id: [0-9a-f-]+' "$SUBMIT_LOG" | awk '{print $2}' || true)"
STATUS="$(grep -Eo 'status: [A-Za-z ]+' "$SUBMIT_LOG" | tail -1 | sed 's/status: //' || true)"

# Anything other than an Accepted verdict must stop the release: an unstapled or
# rejected DMG looks fine locally and fails on every user's machine.
if [[ "$NOTARY_RC" -ne 0 || "$STATUS" != "Accepted" ]]; then
    echo "error: notarization failed (status: ${STATUS:-unknown}, id: ${SUBMISSION_ID:-unknown})" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "==> notarytool log for $SUBMISSION_ID:" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
fi
echo "==> notarization accepted (id: $SUBMISSION_ID)"

# Staple the ticket into the DMG so it validates without a network round-trip.
echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Final check: exactly what Gatekeeper does when a user opens the downloaded DMG.
echo "==> gatekeeper assessment"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo "==> notarized and stapled: $ROOT/$DMG"
