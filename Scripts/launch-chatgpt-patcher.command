#!/bin/bash
# Double-click this file in Finder, or run it from Terminal, to build and open
# the native patcher UI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/ChatGPTPatcher/build-app.sh"
APP_PATH="$SCRIPT_DIR/ChatGPTPatcher/ChatGPT Patcher.app"

"$BUILD_SCRIPT"
open "$APP_PATH"
