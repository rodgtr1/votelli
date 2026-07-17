#!/usr/bin/env bash
# Assemble Votelli.app from the SwiftPM build output, bundling whisper dylibs
# and the model, then ad-hoc code sign it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP="Votelli.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
WHISPER_BIN="third_party/whisper.cpp/build/bin"
MODEL="Resources/ggml-base.en.bin"

if [[ ! -f "$MODEL" ]]; then
    echo "error: $MODEL missing. Run 'make model' first." >&2
    exit 1
fi
if [[ ! -d "$WHISPER_BIN" ]]; then
    echo "error: whisper not built. Run 'make whisper' first." >&2
    exit 1
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Votelli"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES" "$FRAMEWORKS"

cp "$BIN" "$MACOS/Votelli"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/Votelli.icns "$RES/"          # app icon (CFBundleIconFile = Votelli)
cp "$MODEL" "$RES/"

# Bundle whisper + ggml dylibs (preserve version symlinks).
cp -a "$WHISPER_BIN"/libwhisper*.dylib "$FRAMEWORKS/"
cp -a "$WHISPER_BIN"/libggml*.dylib "$FRAMEWORKS/"

# Embed Sparkle.framework. `swift build` links the app against Sparkle but does
# NOT copy the framework into the .app, so we do it here. Locate the prebuilt
# binary slice SwiftPM unpacked under .build/artifacts (path/naming varies by
# SwiftPM version, so search rather than hardcode).
SPARKLE_FW=$(find .build -type d -name Sparkle.framework -path '*artifacts*' | head -1)
if [[ -z "$SPARKLE_FW" ]]; then
    # Fallback: any Sparkle.framework under .build (e.g. a copied build product).
    SPARKLE_FW=$(find .build -type d -name Sparkle.framework | head -1)
fi
if [[ -z "$SPARKLE_FW" ]]; then
    echo "error: Sparkle.framework not found under .build. Run 'make build' first" >&2
    echo "       so SwiftPM fetches the Sparkle binary artifact." >&2
    exit 1
fi
# ditto preserves the versioned bundle layout and its symlinks (Versions/B,
# Versions/Current -> B, and the top-level symlinks into Current). A plain
# cp -RL / rsync-without-l would dereference those symlinks and produce a
# structurally invalid, un-signable framework. Sparkle 2's version dir is B.
ditto "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"
EMBEDDED_SPARKLE="$FRAMEWORKS/Sparkle.framework"

# This app is NOT sandboxed, so Sparkle's XPC services (sandbox-only helpers for
# downloading/installing under App Sandbox) are dead weight — and signing them
# would only add surface to get wrong. Remove them; Autoupdate + Updater.app stay.
rm -rf "$EMBEDDED_SPARKLE/Versions/B/XPCServices"

# Point the executable at the bundled frameworks. Both the whisper dylibs and
# Sparkle.framework live in Contents/Frameworks, so this single rpath resolves
# @rpath/Sparkle.framework/... too.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Votelli" 2>/dev/null || true

# Make the bundled dylibs self-contained: drop the absolute build-dir rpath that
# CMake baked in, and let each dylib resolve its @rpath siblings via @loader_path.
BUILD_RPATH="$ROOT/$WHISPER_BIN"
for dylib in "$FRAMEWORKS"/*.dylib; do
    [[ -L "$dylib" ]] && continue  # skip version symlinks
    install_name_tool -delete_rpath "$BUILD_RPATH" "$dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
done

# Pick the signing identity. macOS keys the user's TCC grants (Microphone /
# Accessibility / Input Monitoring) to the signing certificate's leaf hash, so
# signing every release with the *same* identity is what lets permissions survive
# app updates. Ad-hoc signing changes the code identity and forces every user to
# re-grant — so release builds (REQUIRE_STABLE_IDENTITY=1) refuse it.
#
# Release builds sign with the Developer ID certificate named by EXPECTED_LEAF_HASH
# (selected by hash, not name, so a same-named cert can't silently substitute) and
# add hardened runtime + a secure timestamp, both of which notarization requires.
# Dev builds keep using the self-signed "Votelli Dev" identity: no hardened runtime,
# no timestamp server, so they keep working offline and don't churn local TCC grants.
RELEASE_SIGN=0
if [[ "${REQUIRE_STABLE_IDENTITY:-0}" == "1" ]]; then
    if [[ -z "${EXPECTED_LEAF_HASH:-}" ]]; then
        echo "error: REQUIRE_STABLE_IDENTITY=1 but EXPECTED_LEAF_HASH is unset. Release" >&2
        echo "       signing selects the identity by leaf hash; refusing to guess." >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qi "$EXPECTED_LEAF_HASH"; then
        echo "error: release signing identity $EXPECTED_LEAF_HASH not found in the default" >&2
        echo "       keychain search list. Signing a release with any other identity would" >&2
        echo "       change the app's code identity and force every existing user to re-grant" >&2
        echo "       Microphone / Accessibility / Input Monitoring — and notarization needs" >&2
        echo "       the Developer ID key. Import it from your backup before releasing." >&2
        exit 1
    fi
    SIGN_ID="$EXPECTED_LEAF_HASH"
    RELEASE_SIGN=1
    echo "==> code signing (release: Developer ID $EXPECTED_LEAF_HASH)"
elif security find-identity -p codesigning ~/Library/Keychains/votelli-dev.keychain-db 2>/dev/null | grep -q "Votelli Dev"; then
    SIGN_ID="Votelli Dev"
    echo "==> code signing (Votelli Dev)"
else
    SIGN_ID="-"
    echo "==> code signing (ad-hoc — run scripts/setup_signing.sh for stable identity)"
fi

# Sign nested dylibs first, then the app bundle. Release signing is fatal on error;
# a dylib that silently failed to sign would fail notarization later anyway.
if [[ "$RELEASE_SIGN" == "1" ]]; then
    for dylib in "$FRAMEWORKS"/*.dylib; do
        [[ -L "$dylib" ]] && continue  # skip version symlinks
        codesign --force --sign "$SIGN_ID" --timestamp "$dylib"
    done
    # Sign Sparkle inside-out — the nested helpers first, then the framework, all
    # BEFORE the app is signed below (a nested item re-signed after its container
    # invalidates the container's seal). Each Sparkle executable carries its OWN
    # identity plus hardened runtime + secure timestamp (notarization needs both);
    # crucially, NONE get the app's entitlements — the updater helpers must not
    # inherit Microphone/Accessibility. No --deep anywhere: Sparkle's own guidance
    # is that --deep mis-signs its nested code; we name each piece explicitly.
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$EMBEDDED_SPARKLE/Versions/B/Updater.app"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$EMBEDDED_SPARKLE/Versions/B/Autoupdate"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$EMBEDDED_SPARKLE"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        --entitlements Resources/Votelli.entitlements "$APP"
    echo "==> verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    for dylib in "$FRAMEWORKS"/*.dylib; do
        codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib" >/dev/null 2>&1 || true
    done
    # Same inside-out order as the release path, with the dev identity and no
    # hardened runtime / timestamp (so it works offline and doesn't churn TCC).
    # Errors are NOT swallowed here (unlike the dylibs): Sparkle must be signed
    # correctly for `codesign --verify --strict` to pass, so a failure should be
    # loud. Still no app entitlements on the helpers and no --deep.
    codesign --force --sign "$SIGN_ID" --timestamp=none "$EMBEDDED_SPARKLE/Versions/B/Updater.app"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$EMBEDDED_SPARKLE/Versions/B/Autoupdate"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$EMBEDDED_SPARKLE"
    codesign --force --sign "$SIGN_ID" --entitlements Resources/Votelli.entitlements "$APP"
fi

# Surface the designated requirement, then check the actual leaf certificate. The
# leaf hash must stay identical across releases or users lose their permission
# grants on update. Read it off the signature itself rather than the designated
# requirement: a Developer ID DR names the cert by subject, not by hash.
DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
echo "==> $DR"
if [[ -n "${EXPECTED_LEAF_HASH:-}" ]]; then
    CERTDIR="$(mktemp -d)"
    trap 'rm -rf "$CERTDIR"' EXIT
    codesign -d --extract-certificates="$CERTDIR/cert" "$APP" >/dev/null 2>&1
    LEAF_HASH="$(openssl x509 -inform DER -in "$CERTDIR/cert0" -noout -fingerprint -sha1 2>/dev/null \
        | sed -e 's/.*=//' -e 's/://g' | tr 'A-Z' 'a-z')"
    if [[ "$LEAF_HASH" == "$(echo "$EXPECTED_LEAF_HASH" | tr 'A-Z' 'a-z')" ]]; then
        echo "==> signing identity matches expected leaf hash"
    else
        echo "error: signing identity changed — leaf hash $LEAF_HASH does not match" >&2
        echo "       EXPECTED_LEAF_HASH ($EXPECTED_LEAF_HASH). Shipping this would break TCC" >&2
        echo "       permission continuity for existing users. Restore the original identity" >&2
        echo "       before release." >&2
        exit 1
    fi
fi

echo "==> done: $ROOT/$APP"
