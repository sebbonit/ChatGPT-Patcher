#!/bin/bash
# Builds the self-contained native macOS launcher next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ChatGPT Patcher.app"
APP_PATH="$SCRIPT_DIR/$APP_NAME"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
EXECUTABLE_PATH="$MACOS_PATH/ChatGPT Patcher"

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

/usr/bin/swiftc \
  -parse-as-library \
  "$SCRIPT_DIR/ChatGPTPatcher.swift" \
  -o "$EXECUTABLE_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$SCRIPT_DIR/../patch-model-slider.sh" "$RESOURCES_PATH/patch-model-slider.sh"
cp "$SCRIPT_DIR/../patch-hide-profile-menu.js" "$RESOURCES_PATH/patch-hide-profile-menu.js"
cp "$SCRIPT_DIR/../patch-labels.js" "$RESOURCES_PATH/patch-labels.js"
cp "$SCRIPT_DIR/../install-opencodego-provider.sh" "$RESOURCES_PATH/install-opencodego-provider.sh"
cp "$SCRIPT_DIR/../opencodego-adapter.js" "$RESOURCES_PATH/opencodego-adapter.js"
cp "$SCRIPT_DIR/../opencodego-auth.js" "$RESOURCES_PATH/opencodego-auth.js"
cp "$SCRIPT_DIR/../opencodego-models.json" "$RESOURCES_PATH/opencodego-models.json"
cp "$SCRIPT_DIR/../opencodego-runtime.js" "$RESOURCES_PATH/opencodego-runtime.js"
cp "$SCRIPT_DIR/../opencodego-codex-wrapper.sh" "$RESOURCES_PATH/opencodego-codex-wrapper.sh"
cp "$SCRIPT_DIR/../opencodego-app-wrapper.sh" "$RESOURCES_PATH/opencodego-app-wrapper.sh"
cp "$SCRIPT_DIR/../opencodego-codex-proxy.js" "$RESOURCES_PATH/opencodego-codex-proxy.js"
chmod +x \
  "$EXECUTABLE_PATH" \
  "$RESOURCES_PATH/patch-model-slider.sh" \
  "$RESOURCES_PATH/install-opencodego-provider.sh" \
  "$RESOURCES_PATH/opencodego-adapter.js" \
  "$RESOURCES_PATH/opencodego-auth.js" \
  "$RESOURCES_PATH/opencodego-runtime.js" \
  "$RESOURCES_PATH/opencodego-codex-wrapper.sh" \
  "$RESOURCES_PATH/opencodego-app-wrapper.sh"
/usr/bin/codesign --force --sign - "$APP_PATH"

echo "Built: $APP_PATH"
