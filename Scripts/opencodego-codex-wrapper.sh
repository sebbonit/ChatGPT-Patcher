#!/bin/bash

set -euo pipefail

RESOURCES_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVIDER_DIR="$RESOURCES_DIR/opencodego-provider"
REAL_CODEX="$RESOURCES_DIR/codex-openai-original"
NODE_BIN="$RESOURCES_DIR/cua_node/bin/node"

if [ ! -x "$NODE_BIN" ]; then
    NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$REAL_CODEX" ]; then
    echo "OpenCode Go patched runtime is incomplete. Re-run ChatGPT Patcher." >&2
    exit 1
fi

APP_NAME="$(basename "$(cd "$RESOURCES_DIR/../.." && pwd)" .app)"
INSTANCE_NAME="$(printf '%s' "$APP_NAME" | tr -cs 'A-Za-z0-9._-' '_')"
RUNTIME_DIR="$HOME/Library/Application Support/ChatGPT Patcher/OpenCodeGo/$INSTANCE_NAME/runtime"

"$NODE_BIN" "$PROVIDER_DIR/opencodego-runtime.js" \
    "$HOME/.codex/config.toml" \
    "$RUNTIME_DIR" \
    "$PROVIDER_DIR" \
    "$NODE_BIN"

json_quote() {
    "$NODE_BIN" -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}
CATALOG_JSON="$(json_quote "$RUNTIME_DIR/combined-models.json")"
NODE_JSON="$(json_quote "$NODE_BIN")"
AUTH_JSON="$(json_quote "$PROVIDER_DIR/opencodego-auth.js")"
CONFIG_ARGS=(
    -c "model_catalog_json=$CATALOG_JSON"
    -c 'model_providers.opencodego.name="OpenCode Go"'
    -c 'model_providers.opencodego.base_url="http://127.0.0.1:42429"'
    -c 'model_providers.opencodego.wire_api="responses"'
    -c 'model_providers.opencodego.stream_idle_timeout_ms=300000'
    -c "model_providers.opencodego.auth.command=$NODE_JSON"
    -c "model_providers.opencodego.auth.args=[$AUTH_JSON]"
    -c 'model_providers.opencodego.auth.timeout_ms=5000'
)
if printf '%s\n' "$@" | grep -qx 'app-server'; then
    exec "$NODE_BIN" "$PROVIDER_DIR/opencodego-codex-proxy.js" \
        "$REAL_CODEX" "$PROVIDER_DIR/opencodego-models.json" -- "${CONFIG_ARGS[@]}" "$@"
fi
exec "$REAL_CODEX" "${CONFIG_ARGS[@]}" "$@"
