#!/usr/bin/env bash
# Assemble Murmur.app from the SwiftPM build output, bundling whisper dylibs
# and the model, then ad-hoc code sign it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP="Murmur.app"
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
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Murmur"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES" "$FRAMEWORKS"

cp "$BIN" "$MACOS/Murmur"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp "$MODEL" "$RES/"

# Bundle whisper + ggml dylibs (preserve version symlinks).
cp -a "$WHISPER_BIN"/libwhisper*.dylib "$FRAMEWORKS/"
cp -a "$WHISPER_BIN"/libggml*.dylib "$FRAMEWORKS/"

# Point the executable at the bundled frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Murmur" 2>/dev/null || true

# Make the bundled dylibs self-contained: drop the absolute build-dir rpath that
# CMake baked in, and let each dylib resolve its @rpath siblings via @loader_path.
BUILD_RPATH="$ROOT/$WHISPER_BIN"
for dylib in "$FRAMEWORKS"/*.dylib; do
    [[ -L "$dylib" ]] && continue  # skip version symlinks
    install_name_tool -delete_rpath "$BUILD_RPATH" "$dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
done

# Prefer the stable self-signed identity (keeps TCC permissions across rebuilds);
# fall back to ad-hoc if it hasn't been set up.
if security find-identity -p codesigning ~/Library/Keychains/murmur-dev.keychain-db 2>/dev/null | grep -q "Murmur Dev"; then
    SIGN_ID="Murmur Dev"
    echo "==> code signing (Murmur Dev)"
else
    SIGN_ID="-"
    echo "==> code signing (ad-hoc — run scripts/setup_signing.sh for stable identity)"
fi

# Sign nested dylibs first, then the app bundle.
for dylib in "$FRAMEWORKS"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib" >/dev/null 2>&1 || true
done
codesign --force --sign "$SIGN_ID" --entitlements Resources/Murmur.entitlements "$APP"

echo "==> done: $ROOT/$APP"
