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
cp "$MODEL" "$RES/"

# Bundle whisper + ggml dylibs (preserve version symlinks).
cp -a "$WHISPER_BIN"/libwhisper*.dylib "$FRAMEWORKS/"
cp -a "$WHISPER_BIN"/libggml*.dylib "$FRAMEWORKS/"

# Point the executable at the bundled frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Votelli" 2>/dev/null || true

# Make the bundled dylibs self-contained: drop the absolute build-dir rpath that
# CMake baked in, and let each dylib resolve its @rpath siblings via @loader_path.
BUILD_RPATH="$ROOT/$WHISPER_BIN"
for dylib in "$FRAMEWORKS"/*.dylib; do
    [[ -L "$dylib" ]] && continue  # skip version symlinks
    install_name_tool -delete_rpath "$BUILD_RPATH" "$dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
done

# Prefer the stable self-signed identity. macOS keys the user's TCC grants
# (Microphone / Accessibility / Input Monitoring) to this certificate's leaf hash,
# so signing every release with the *same* identity is what lets permissions
# survive app updates. Ad-hoc signing changes the code identity and forces every
# user to re-grant — so release builds (REQUIRE_STABLE_IDENTITY=1) refuse it.
if security find-identity -p codesigning ~/Library/Keychains/votelli-dev.keychain-db 2>/dev/null | grep -q "Votelli Dev"; then
    SIGN_ID="Votelli Dev"
    echo "==> code signing (Votelli Dev)"
elif [[ "${REQUIRE_STABLE_IDENTITY:-0}" == "1" ]]; then
    echo "error: stable 'Votelli Dev' identity not found, but REQUIRE_STABLE_IDENTITY=1." >&2
    echo "       Signing a release ad-hoc would change the app's code identity and force" >&2
    echo "       every existing user to re-grant Microphone / Accessibility / Input Monitoring." >&2
    echo "       Restore the identity from your .p12 backup, or run scripts/setup_signing.sh" >&2
    echo "       (note: a freshly generated identity has a NEW leaf hash and breaks continuity)." >&2
    exit 1
else
    SIGN_ID="-"
    echo "==> code signing (ad-hoc — run scripts/setup_signing.sh for stable identity)"
fi

# Sign nested dylibs first, then the app bundle.
for dylib in "$FRAMEWORKS"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib" >/dev/null 2>&1 || true
done
codesign --force --sign "$SIGN_ID" --entitlements Resources/Votelli.entitlements "$APP"

# Surface the designated requirement; the leaf hash here must stay identical
# across releases or users lose their permission grants on update.
DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
echo "==> $DR"
if [[ -n "${EXPECTED_LEAF_HASH:-}" ]]; then
    if echo "$DR" | grep -qi "$EXPECTED_LEAF_HASH"; then
        echo "==> signing identity matches expected leaf hash"
    else
        echo "error: signing identity changed — leaf hash does not match EXPECTED_LEAF_HASH" >&2
        echo "       ($EXPECTED_LEAF_HASH). Shipping this would break TCC permission" >&2
        echo "       continuity for existing users. Restore the original identity before release." >&2
        exit 1
    fi
fi

echo "==> done: $ROOT/$APP"
