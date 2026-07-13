#!/bin/bash

set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE_NAME="$(basename "$0")"
REAL_EXECUTABLE="$MACOS_DIR/${EXECUTABLE_NAME}-openai-original"
if [ ! -x "$REAL_EXECUTABLE" ]; then
    echo "OpenCode Go patched app runtime is incomplete. Re-run ChatGPT Patcher." >&2
    exit 1
fi

exec "$REAL_EXECUTABLE" "$@"
