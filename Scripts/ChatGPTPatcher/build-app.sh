#!/bin/bash
# Builds the self-contained native macOS launcher next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ChatGPT Patcher.app"
APP_PATH="${PATCHER_APP_PATH:-$SCRIPT_DIR/$APP_NAME}"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
EXECUTABLE_PATH="$MACOS_PATH/ChatGPT Patcher"
PATCHER_VERSION="${PATCHER_VERSION:-1.0.0}"
PATCHER_BUILD_NUMBER="${PATCHER_BUILD_NUMBER:-1}"
PATCHER_ARCHS="${PATCHER_ARCHS:-$(uname -m)}"

mkdir -p "$(dirname "$APP_PATH")" "$MACOS_PATH" "$RESOURCES_PATH"

if [[ "$PATCHER_ARCHS" == "universal" ]]; then
  for architecture in arm64 x86_64; do
    /usr/bin/swiftc \
      -parse-as-library \
      -target "$architecture-apple-macos13.0" \
      "$SCRIPT_DIR/ChatGPTPatcher.swift" \
      -o "$EXECUTABLE_PATH.$architecture" \
      -framework AppKit \
      -framework SwiftUI \
      -framework UniformTypeIdentifiers
  done
  /usr/bin/lipo -create \
    "$EXECUTABLE_PATH.arm64" \
    "$EXECUTABLE_PATH.x86_64" \
    -output "$EXECUTABLE_PATH"
  rm -f "$EXECUTABLE_PATH.arm64" "$EXECUTABLE_PATH.x86_64"
else
  /usr/bin/swiftc \
    -parse-as-library \
    "$SCRIPT_DIR/ChatGPTPatcher.swift" \
    -o "$EXECUTABLE_PATH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers
fi

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_PATH/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$PATCHER_VERSION" "$CONTENTS_PATH/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$PATCHER_BUILD_NUMBER" "$CONTENTS_PATH/Info.plist"
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
