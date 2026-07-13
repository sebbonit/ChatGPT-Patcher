#!/bin/bash

set -euo pipefail

APP_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH/Contents/Resources" ]; then
    echo "ERROR: Pass the staging app bundle to the OpenCode Go installer." >&2
    exit 1
fi

RESOURCES_DIR="$APP_PATH/Contents/Resources"
CODEX_LAUNCHER="$RESOURCES_DIR/codex"
REAL_CODEX="$RESOURCES_DIR/codex-openai-original"
PROVIDER_DIR="$RESOURCES_DIR/opencodego-provider"

for asset in opencodego-adapter.js opencodego-auth.js opencodego-models.json opencodego-runtime.js opencodego-codex-wrapper.sh opencodego-codex-proxy.js opencodego-app-wrapper.sh; do
    if [ ! -f "$SCRIPT_DIR/$asset" ]; then
        echo "ERROR: OpenCode Go asset is missing: $SCRIPT_DIR/$asset" >&2
        exit 1
    fi
done

INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
APP_LAUNCHER="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
REAL_APP_EXECUTABLE="$APP_PATH/Contents/MacOS/${APP_EXECUTABLE}-openai-original"

if [ ! -e "$REAL_APP_EXECUTABLE" ]; then
    if [ ! -x "$APP_LAUNCHER" ]; then
        echo "ERROR: The app executable was not found: $APP_LAUNCHER" >&2
        exit 1
    fi
    mv "$APP_LAUNCHER" "$REAL_APP_EXECUTABLE"
fi
cp "$SCRIPT_DIR/opencodego-app-wrapper.sh" "$APP_LAUNCHER"
chmod 755 "$APP_LAUNCHER" "$REAL_APP_EXECUTABLE"

# Give the generated copy its own LaunchServices identity. Together with the
# dedicated Chromium data directory above, this prevents a running stock app
# from claiming the patched app's launch and window.
ORIGINAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :ChatGPTPatcherOriginalBundleIdentifier' "$INFO_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if ! /usr/libexec/PlistBuddy -c 'Print :ChatGPTPatcherOriginalBundleIdentifier' "$INFO_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :ChatGPTPatcherOriginalBundleIdentifier string $ORIGINAL_BUNDLE_ID" "$INFO_PLIST"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${ORIGINAL_BUNDLE_ID}.chatgptpatcher.opencodego" "$INFO_PLIST"

# The original main executable's embedded signature includes the bundle's
# Info.plist. Re-sign the renamed executable after changing the bundle ID so
# the final deep verification can validate it as a nested code object.
/usr/bin/codesign --force --sign - "$REAL_APP_EXECUTABLE"

if [ ! -e "$REAL_CODEX" ]; then
    if [ ! -x "$CODEX_LAUNCHER" ]; then
        echo "ERROR: The app's bundled Codex executable was not found: $CODEX_LAUNCHER" >&2
        exit 1
    fi
    mv "$CODEX_LAUNCHER" "$REAL_CODEX"
fi

mkdir -p "$PROVIDER_DIR"
cp "$SCRIPT_DIR/opencodego-adapter.js" "$PROVIDER_DIR/opencodego-adapter.js"
cp "$SCRIPT_DIR/opencodego-auth.js" "$PROVIDER_DIR/opencodego-auth.js"
cp "$SCRIPT_DIR/opencodego-models.json" "$PROVIDER_DIR/opencodego-models.json"
cp "$SCRIPT_DIR/opencodego-runtime.js" "$PROVIDER_DIR/opencodego-runtime.js"
cp "$SCRIPT_DIR/opencodego-codex-proxy.js" "$PROVIDER_DIR/opencodego-codex-proxy.js"
cp "$SCRIPT_DIR/opencodego-codex-wrapper.sh" "$CODEX_LAUNCHER"
chmod 755 "$CODEX_LAUNCHER" "$REAL_CODEX" \
    "$PROVIDER_DIR/opencodego-adapter.js" \
    "$PROVIDER_DIR/opencodego-auth.js" \
    "$PROVIDER_DIR/opencodego-runtime.js"

echo "  OpenCode Go runtime embedded in: $APP_PATH"
echo "  Patched app identity: ${ORIGINAL_BUNDLE_ID}.chatgptpatcher.opencodego"
echo "  Original ~/.codex configuration will not be modified."
