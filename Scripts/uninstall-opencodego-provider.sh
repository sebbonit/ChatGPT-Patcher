#!/bin/bash

set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH/Contents/Resources" ]; then
    echo "Usage: $0 /path/to/patched.app" >&2
    echo "This command never changes ~/.codex/config.toml." >&2
    exit 1
fi

RESOURCES_DIR="$APP_PATH/Contents/Resources"
if [ ! -x "$RESOURCES_DIR/codex-openai-original" ]; then
    echo "ERROR: This app does not contain the isolated OpenCode Go runtime." >&2
    exit 1
fi

mv "$RESOURCES_DIR/codex-openai-original" "$RESOURCES_DIR/codex"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
if [ -x "$APP_PATH/Contents/MacOS/${APP_EXECUTABLE}-openai-original" ]; then
    mv "$APP_PATH/Contents/MacOS/${APP_EXECUTABLE}-openai-original" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
fi
ORIGINAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :ChatGPTPatcherOriginalBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
if [ -n "$ORIGINAL_BUNDLE_ID" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ORIGINAL_BUNDLE_ID" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c 'Delete :ChatGPTPatcherOriginalBundleIdentifier' "$INFO_PLIST"
fi
/usr/bin/codesign --force --sign - "$APP_PATH"
echo "Restored the app's original bundled Codex launcher."
echo "The user-wide Codex configuration was not changed."
