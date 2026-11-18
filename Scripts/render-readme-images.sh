#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
    echo 'README images must be rendered on macOS.' >&2
    exit 1
fi
swift build --package-path "$ROOT" --product Squished
BIN_DIR=$(swift build --package-path "$ROOT" --show-bin-path)
"$BIN_DIR/Squished" --readme-images "$ROOT/docs/images"
