#!/usr/bin/env bash
# Build whisper.cpp as Metal-accelerated shared libraries for Murmur.
# Outputs dylibs under third_party/whisper.cpp/build/ that the app bundles.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/third_party/whisper.cpp"
BUILD="$SRC/build"

cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=ON \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF

cmake --build "$BUILD" --config Release -j"$(sysctl -n hw.ncpu)"

echo "=== Built dylibs ==="
find "$BUILD" -name '*.dylib' -maxdepth 4 -print
