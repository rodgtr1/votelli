#!/usr/bin/env bash
# Download the bundled whisper model if it isn't present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="$ROOT/Resources/ggml-base.en.bin"

if [[ -f "$MODEL" ]]; then
    echo "model already present: $MODEL"
    exit 0
fi

echo "==> downloading ggml-base.en model"
bash "$ROOT/third_party/whisper.cpp/models/download-ggml-model.sh" base.en "$ROOT/Resources"
