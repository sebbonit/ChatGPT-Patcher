#!/bin/bash
#
# patch-model-slider.sh
#
# Applies selected ChatGPT Patcher features: a configurable model slider,
# hiding profile-menu clutter (Show pet / Invite a friend), and/or the
# OpenCode Go provider with its local Responses compatibility adapter.
#
# Re-run this after every ChatGPT app update to re-apply the patch.
#
# Usage:
#   ./Scripts/patch-model-slider.sh                          # patches ./ChatGPT-Hello.app
#   ./Scripts/patch-model-slider.sh /path/to/SomeApp.app     # patches a custom app bundle
#
# The native UI never passes an original app to this low-level worker. It first
# creates a private duplicate in the chosen output folder, then invokes this
# script only on that staging copy.
#
# Requirements:
#   - Node.js / npx
#   - @electron/asar (auto-installed via npx if missing)
#
# What it does:
#   1. Backs up the original app.asar (only the first time)
#   2. Extracts the asar to a temp directory
#   3. Finds the JS file containing the model picker slider arrays
#   4. Replaces both slider arrays with the custom slider points
#   5. Patches the development banner in index.html (toggleable)
#   6. Repacks the asar into the app bundle
#   7. Verifies both patches
#   8. Updates Electron's ASAR integrity hash
#   9. Embeds selected provider runtime and signs the patched copy
#  10. Clears inherited quarantine metadata from the patched copy
#
# The development banner shows "Development Build" at the top of the window.
# Click it to hide it; click the small "Dev" hint (bottom-right) to show it again.
#
# If the pattern can't be found (e.g. the app was updated with renamed models
# or a restructured picker), the script warns you and exits without modifying
# anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER_FEATURES="${PATCHER_FEATURES:-custom-model-slider}"
has_feature() {
    case ",$PATCHER_FEATURES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Configuration ---------------------------------------------------------

# Finder-launched applications do not inherit a shell's usual PATH. Include
# common Node.js locations so the native UI works with Homebrew installs too.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

NODE_BIN="$(command -v node || true)"
NPX_BIN="$(command -v npx || true)"

if [ -z "$NODE_BIN" ] || [ -z "$NPX_BIN" ]; then
    echo "ERROR: Node.js and npx are required."
    echo "Install Node.js, then run this patcher again."
    exit 1
fi

# Default app bundle path (a local copy, not the installed /Applications app)
APP_PATH="${1:-$(cd "$(dirname "$0")/.." && pwd)/ChatGPT-Hello.app}"

# The asar file inside the app bundle
ASAR_PATH="$APP_PATH/Contents/Resources/app.asar"

# Electron stores a hash of the ASAR header in Info.plist and refuses to load
# an archive when the two do not match.
INFO_PLIST="$APP_PATH/Contents/Info.plist"

# Backup location (next to the original, only created once)
ASAR_BACKUP="$ASAR_PATH.original-backup"
INFO_PLIST_BACKUP="$INFO_PLIST.original-backup"
SKIP_BACKUP="${PATCHER_SKIP_BACKUP:-0}"

# Temp directory for extraction
WORK_DIR="$(mktemp -d)"
EXTRACTED_DIR="$WORK_DIR/extracted"
PACKED_ASAR=""

# Cleanup on exit
trap 'rm -rf "$WORK_DIR"; [ -z "${PACKED_ASAR:-}" ] || rm -f "$PACKED_ASAR"' EXIT

# --- Custom slider points (left to right) ----------------------------------
# Each entry: "model:effort"
# The modelLabel is derived from the model name (e.g. "gpt-5.6-luna" -> "5.6 Luna").
SLIDER_POINTS=(
    "gpt-5.6-luna:medium"
    "gpt-5.6-luna:high"
    "gpt-5.6-luna:xhigh"
    "gpt-5.6-luna:max"
    "gpt-5.6-sol:low"
    "gpt-5.6-sol:medium"
    "gpt-5.6-sol:high"
    "gpt-5.6-sol:xhigh"
    "gpt-5.6-sol:max"
    "gpt-5.6-terra:medium"
    "gpt-5.6-terra:high"
    "gpt-5.6-terra:xhigh"
)

# Points enabled on the composer slider by default (left to right).
ACTIVE_SLIDER_POINTS=(
    "gpt-5.6-luna:medium"
    "gpt-5.6-luna:high"
    "gpt-5.6-luna:xhigh"
    "gpt-5.6-luna:max"
    "gpt-5.6-sol:low"
    "gpt-5.6-sol:medium"
    "gpt-5.6-sol:high"
    "gpt-5.6-sol:xhigh"
    "gpt-5.6-sol:max"
)

# Used when the composer does not already have a valid point selected.
DEFAULT_SLIDER_POINT="gpt-5.6-sol:medium"
SLIDER_STORAGE_KEY="chatgpt-patcher.slider-order"

if has_feature "opencodego-provider"; then
    SLIDER_POINTS+=(
        "glm-5:none"
        "glm-5.1:none"
        "glm-5.2:high"
        "glm-5.2:max"
        "kimi-k2.5:none"
        "kimi-k2.6:none"
        "kimi-k2.7-code:none"
        "mimo-v2-pro:none"
        "mimo-v2-omni:none"
        "mimo-v2.5-pro:none"
        "mimo-v2.5:none"
        "minimax-m2.5:none"
        "minimax-m2.7:none"
        "minimax-m3:none"
        "qwen3.5-plus:none"
        "qwen3.6-plus:none"
        "qwen3.7-plus:none"
        "qwen3.7-max:none"
        "deepseek-v4-pro:max"
        "deepseek-v4-flash:none"
        "hy3-preview:none"
        "kimi-k3:low"
        "kimi-k3:high"
        "kimi-k3:max"
        "grok-4.5:none"
    )
    # Bump the namespace so an earlier OpenCode-only build cannot restore its
    # stale ordering and re-enable every provider model on first launch.
    SLIDER_STORAGE_KEY="chatgpt-patcher.slider-order-providers-v2"
fi

# --- Main ------------------------------------------------------------------

echo "=== ChatGPT Patcher ==="
echo ""

# Check the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at: $APP_PATH"
    echo "Usage: $0 [/path/to/ChatGPT.app]"
    exit 1
fi

if [ ! -f "$ASAR_PATH" ]; then
    echo "ERROR: app.asar not found at: $ASAR_PATH"
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: Info.plist not found at: $INFO_PLIST"
    exit 1
fi

echo "App bundle:  $APP_PATH"
echo "Asar:        $ASAR_PATH"
echo ""

PROVIDER_INSTALLER="$SCRIPT_DIR/install-opencodego-provider.sh"
HAS_ASAR_FEATURE=0
if has_feature "custom-model-slider" || has_feature "hide-profile-menu-items"; then
    HAS_ASAR_FEATURE=1
fi

if has_feature "opencodego-provider" && [ "$HAS_ASAR_FEATURE" -eq 0 ]; then
    if [ ! -x "$PROVIDER_INSTALLER" ]; then
        echo "ERROR: OpenCode Go provider installer is missing: $PROVIDER_INSTALLER"
        exit 1
    fi
    echo "Installing OpenCode Go provider and Responses compatibility adapter..."
    "$PROVIDER_INSTALLER" "$APP_PATH"
    echo ""
fi

if [ "$HAS_ASAR_FEATURE" -eq 0 ]; then
    echo "No ASAR feature selected; the copied app bundle does not need JavaScript changes."
    echo "Signing the provider-enabled app for local launch..."
    /usr/bin/codesign --force --sign - "$APP_PATH"
    /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    /usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    echo "=== Patch complete! ==="
    exit 0
fi

# Step 1: Back up the original files (only if no backup exists yet)
if [ "$SKIP_BACKUP" = "1" ]; then
    # The native UI always works on a disposable staging duplicate, so the
    # separately preserved source app is the backup. Remove stale internal
    # backups copied from an older patched source because they interfere with
    # signing the generated app bundle.
    rm -f "$ASAR_BACKUP" "$INFO_PLIST_BACKUP"
    echo "Step 1: Source app is preserved by the UI; internal backup skipped."
elif [ ! -f "$ASAR_BACKUP" ]; then
    echo "Step 1: Backing up original app.asar..."
    cp "$ASAR_PATH" "$ASAR_BACKUP"
    echo "  Saved backup to: $ASAR_BACKUP"
else
    echo "Step 1: Backup already exists, skipping ($ASAR_BACKUP)"
fi

if [ "$SKIP_BACKUP" = "1" ]; then
    :
elif [ ! -f "$INFO_PLIST_BACKUP" ]; then
    cp "$INFO_PLIST" "$INFO_PLIST_BACKUP"
    echo "  Saved Info.plist backup to: $INFO_PLIST_BACKUP"
else
    echo "  Info.plist backup already exists, skipping ($INFO_PLIST_BACKUP)"
fi
echo ""

# Step 2: Extract the asar
echo "Step 2: Extracting app.asar..."
"$NPX_BIN" --yes @electron/asar extract "$ASAR_PATH" "$EXTRACTED_DIR"
echo "  Extracted to: $EXTRACTED_DIR"
echo ""

# Step 3 & 4: Optional model-slider ASAR transforms (Node.js for long minified lines)
SLIDER_POINTS_STR=$(printf '%s\n' "${SLIDER_POINTS[@]}")
ACTIVE_SLIDER_POINTS_STR=$(printf '%s\n' "${ACTIVE_SLIDER_POINTS[@]}")
AVAILABLE_SLIDER_POINTS=()
for point in "${SLIDER_POINTS[@]}"; do
    is_active=0
    for active_point in "${ACTIVE_SLIDER_POINTS[@]}"; do
        if [ "$point" = "$active_point" ]; then
            is_active=1
            break
        fi
    done
    if [ "$is_active" -eq 0 ]; then
        AVAILABLE_SLIDER_POINTS+=("$point")
    fi
done
AVAILABLE_SLIDER_POINTS_STR=$(printf '%s\n' "${AVAILABLE_SLIDER_POINTS[@]}")

if has_feature "custom-model-slider"; then
echo "Step 3: Searching for model picker slider arrays..."
echo "Step 4: Replacing slider arrays with custom points..."
echo ""

if ! PATCH_RESULT=$("$NODE_BIN" -e '
const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[1];
const sliderPointsStr = process.argv[2];
const defaultSliderPoint = process.argv[3];
const sliderStorageKey = process.argv[4];
const scriptDir = process.argv[5];
const sliderPoints = sliderPointsStr.split("\n").filter(s => s.length > 0);
const { OPEN_CODE_LABELS } = require(path.join(scriptDir, "patch-labels.js"));

// Build the new array content from slider points
function modelToLabel(model) {
    // "gpt-5.6-luna" -> "5.6 Luna"
    let stripped = model.replace(/^gpt-/, "");
    const label = stripped.split("-").map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
    if (model.startsWith("gpt-")) return label;
    return `OpenCode Go · ${OPEN_CODE_LABELS[model] || label}`;
}

function buildEntry(model, effort) {
    const label = modelToLabel(model);
    return `{id:\`${model}:${effort}\`,model:\`${model}\`,modelLabel:\`${label}\`,reasoningEffort:\`${effort}\`}`;
}

function buildArray() {
    return "[" + sliderPoints.map(p => {
        const [model, effort] = p.split(":");
        return buildEntry(model, effort);
    }).join(",") + "]";
}

const newArray = buildArray();

// Recursively find all .js files in webview/assets/
function findJsFiles(dir) {
    let results = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            results = results.concat(findJsFiles(fullPath));
        } else if (entry.name.endsWith(".js")) {
            results.push(fullPath);
        }
    }
    return results;
}

const assetsDir = path.join(extractedDir, "webview", "assets");
if (!fs.existsSync(assetsDir)) {
    console.error("ERROR: webview/assets directory not found in extracted asar.");
    process.exit(1);
}

const jsFiles = findJsFiles(assetsDir);

// Regex to match a slider array assignment:
// VARNAME=[{id:`...`,model:`...`,modelLabel:`...`,reasoningEffort:`...`},...]
// The objects use backtick-delimited strings and have modelLabel + reasoningEffort fields.
const arrayPattern = /(\w+)=\[(\{[^{}]*modelLabel:[^{}]*reasoningEffort:[^{}]*\}(?:,\{[^{}]*modelLabel:[^{}]*reasoningEffort:[^{}]*\})*)\]/g;

let targetFile = null;
let matches = [];

for (const file of jsFiles) {
    const content = fs.readFileSync(file, "utf8");
    const localMatches = [];
    let match;
    // Reset regex lastIndex
    arrayPattern.lastIndex = 0;
    while ((match = arrayPattern.exec(content)) !== null) {
        localMatches.push({
            fullMatch: match[0],
            varName: match[1],
            start: match.index,
            end: match.index + match[0].length
        });
    }
    // We need a file with at least 2 slider arrays (FRe and IRe)
    if (localMatches.length >= 2) {
        targetFile = file;
        matches = localMatches;
        break;
    }
}

if (!targetFile) {
    console.error("ERROR: Could not find any file with model picker slider arrays (>=2 arrays).");
    console.error("The app may have been updated with a restructured model picker.");
    console.error("Manual inspection is required.");
    process.exit(1);
}

console.log("  Found target file: " + path.basename(targetFile));
console.log("  Found " + matches.length + " slider array(s) to replace.");
console.log("");

// Read the user-managed order from localStorage whenever the bundle initializes.
// Invalid or stale values safely fall back to the full default list.
function configurableArray(catalog, initialIds) {
    const catalogJSON = JSON.stringify(catalog);
    const initialIdsJSON = JSON.stringify(initialIds);
    return `(()=>{const d=${catalogJSON},initial=new Set(${initialIdsJSON}),fallback=d.filter(e=>initial.has(e.id));try{const s=JSON.parse(localStorage.getItem(${JSON.stringify(sliderStorageKey)})||\`null\`);if(!Array.isArray(s))return fallback;const m=new Map(d.map(e=>[e.id,e]));const r=s.filter(e=>e&&e.enabled!==false&&m.has(e.id)).map(e=>m.get(e.id));return r.length?r:fallback}catch{return fallback}})()`;
}

const defaultEntries = sliderPoints.map(p => {
    const [model, effort] = p.split(":");
    return {id: `${model}:${effort}`, model, modelLabel: modelToLabel(model), reasoningEffort: effort};
});
const initialActiveIds = [
    "gpt-5.6-luna:medium", "gpt-5.6-luna:high", "gpt-5.6-luna:xhigh", "gpt-5.6-luna:max",
    "gpt-5.6-sol:low", "gpt-5.6-sol:medium", "gpt-5.6-sol:high", "gpt-5.6-sol:xhigh", "gpt-5.6-sol:max"
];
const initialActiveIdSet = new Set(initialActiveIds);
const runtimeArray = configurableArray(defaultEntries, initialActiveIds);

// Replace all matched arrays with the configurable expression.
// Replace from the end to avoid offset issues
let content = fs.readFileSync(targetFile, "utf8");
for (let i = matches.length - 1; i >= 0; i--) {
    const m = matches[i];
    const replacement = m.varName + "=" + runtimeArray;
    content = content.slice(0, m.start) + replacement + content.slice(m.end);
    console.log("  Replaced array: " + m.varName + " (" + m.fullMatch.length + " chars -> " + replacement.length + " chars)");
}

// Do this after every position-based array replacement. Changing the source
// length before using the recorded offsets would corrupt the minified bundle.
// The native picker otherwise falls back to the first medium-effort point.
// Minified JavaScript identifiers may contain "$" (the current bundle names
// this helper "$0e"), so \w+ is too restrictive here.
const defaultPointPattern = /function ([A-Za-z_$][\w$]*)\(e\)\{return e\.find\(\(\{reasoningEffort:e\}\)=>e===`medium`\)\?\?e\[0\]\}/;
const defaultPointMatch = content.match(defaultPointPattern);
if (!defaultPointMatch) {
    console.error("ERROR: Could not find the model picker default-point helper.");
    process.exit(1);
}
content = content.replace(
    defaultPointPattern,
    `function ${defaultPointMatch[1]}(e){return e.find(e=>e.id===\`${defaultSliderPoint}\`)??e.find(({reasoningEffort:e})=>e===\`medium\`)??e[0]}`
);
console.log("  Set default slider point: " + defaultSliderPoint);

// Add a lightweight settings tab without depending on private React symbols.
// It follows the settings DOM across navigation and stores only slider order.
const settingsBootstrap = `
;(()=>{
if(globalThis.__chatgptPatcherSettingsInstalled)return;
globalThis.__chatgptPatcherSettingsInstalled=true;
const KEY=${JSON.stringify(sliderStorageKey)};
const DEFAULTS=${JSON.stringify(defaultEntries.map(e => ({id:e.id,label:`${e.modelLabel} — ${e.reasoningEffort}`,enabled:initialActiveIdSet.has(e.id)})))};
const css=document.createElement(\"style\");
css.textContent=\`#cgp-tab[data-active=true]{background:rgba(127,127,127,.14)}#cgp-panel{position:fixed;z-index:2147483600;top:0;right:0;bottom:0;overflow:auto;color:inherit;font:inherit}#cgp-panel *{box-sizing:border-box}.cgp-content{width:min(920px,calc(100% - 72px));margin:0 auto;padding:64px 0 48px}.cgp-title{font-size:26px;line-height:1.2;font-weight:500;margin:0 0 9px;letter-spacing:-.02em}.cgp-subtitle{max-width:650px;font-size:14px;line-height:1.5;opacity:.62;margin:0 0 36px}.cgp-section-head{display:flex;align-items:end;justify-content:space-between;gap:20px;margin-bottom:12px}.cgp-section-title{font-size:14px;font-weight:500;margin:0}.cgp-section-hint{font-size:12px;opacity:.5}.cgp-track-shell{border:1px solid rgba(127,127,127,.2);border-radius:16px;background:rgba(127,127,127,.025);padding:16px 16px 18px;box-shadow:0 1px 2px rgba(0,0,0,.025)}.cgp-direction{display:flex;align-items:center;gap:10px;margin:0 4px 12px;font-size:11px;opacity:.48}.cgp-direction-line{height:1px;flex:1;background:linear-gradient(90deg,rgba(127,127,127,.16),rgba(127,127,127,.5),rgba(127,127,127,.16));position:relative}.cgp-direction-line:after{content:\\\"›\\\";position:absolute;right:-1px;top:-9px;font-size:17px}.cgp-track{display:flex;align-items:stretch;gap:10px;min-height:126px;overflow-x:auto;padding:2px 2px 8px;scrollbar-width:thin}.cgp-card{position:relative;flex:0 0 154px;min-width:154px;height:116px;border:1px solid rgba(127,127,127,.2);border-radius:12px;background:rgba(255,255,255,.55);padding:13px;cursor:grab;transition:border-color .15s,transform .15s,box-shadow .15s,opacity .15s}.cgp-card:hover{border-color:rgba(127,127,127,.42);box-shadow:0 5px 16px rgba(0,0,0,.06);transform:translateY(-1px)}.cgp-card.cgp-dragging{opacity:.35;transform:scale(.97)}.cgp-card.cgp-drop{border-color:#339cff;box-shadow:0 0 0 2px rgba(51,156,255,.16)}.cgp-card-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}.cgp-position{display:flex;align-items:center;gap:6px;font-size:10px;opacity:.48}.cgp-grip{font-size:13px;letter-spacing:-2px;transform:rotate(90deg)}.cgp-remove{width:22px;height:22px;border:0;border-radius:6px;background:transparent;color:inherit;opacity:.42;cursor:pointer;font-size:16px;line-height:1}.cgp-remove:hover{background:rgba(127,127,127,.1);opacity:.8}.cgp-remove:disabled{opacity:.15;cursor:default}.cgp-card-model{font-size:13px;font-weight:550;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.cgp-effort{display:inline-flex;margin-top:6px;padding:3px 7px;border-radius:999px;background:rgba(127,127,127,.1);font-size:10px;text-transform:capitalize;opacity:.75}.cgp-card-controls{position:absolute;right:9px;bottom:8px;display:flex;gap:3px}.cgp-card-controls button{width:24px;height:22px;border:0;border-radius:6px;background:transparent;color:inherit;opacity:.42;cursor:pointer}.cgp-card-controls button:hover{background:rgba(127,127,127,.1);opacity:.85}.cgp-card-controls button:disabled{opacity:.14;cursor:default}.cgp-available{margin-top:28px}.cgp-search{width:100%;height:34px;border:1px solid rgba(127,127,127,.2);border-radius:9px;background:rgba(127,127,127,.04);color:inherit;font:inherit;font-size:12px;padding:0 12px;margin-bottom:10px}.cgp-search::placeholder{opacity:.45}.cgp-search:focus{outline:none;border-color:rgba(127,127,127,.42)}.cgp-available-box{display:flex;flex-wrap:wrap;gap:8px;padding:12px;border:1px dashed rgba(127,127,127,.24);border-radius:13px;min-height:50px}.cgp-add{display:inline-flex;align-items:center;gap:7px;height:30px;border:1px solid rgba(127,127,127,.2);border-radius:8px;background:rgba(127,127,127,.04);color:inherit;font:inherit;font-size:11px;padding:0 10px;cursor:pointer}.cgp-add:hover{background:rgba(127,127,127,.1)}.cgp-add-plus{font-size:15px;opacity:.6}.cgp-empty{font-size:12px;opacity:.42;padding:5px}.cgp-footer{display:flex;align-items:center;justify-content:space-between;gap:18px;margin-top:24px}.cgp-note{font-size:12px;opacity:.48}.cgp-actions{display:flex;gap:8px}.cgp-actions button{height:34px;border:1px solid rgba(127,127,127,.22);border-radius:9px;background:transparent;color:inherit;font:inherit;font-size:12px;padding:0 13px;cursor:pointer}.cgp-actions button:hover{background:rgba(127,127,127,.09)}.cgp-actions .cgp-save{border-color:#0d0d0d;background:#0d0d0d;color:#fff;padding:0 17px}@media(prefers-color-scheme:dark){.cgp-card{background:rgba(255,255,255,.035)}.cgp-actions .cgp-save{border-color:#f2f2f2;background:#f2f2f2;color:#111}}@media(max-width:850px){.cgp-content{width:calc(100% - 36px);padding-top:44px}.cgp-subtitle{margin-bottom:28px}}\`;
document.head.appendChild(css);
const nativeCss=document.createElement("style");
nativeCss.textContent="#cgp-panel{position:absolute!important;inset:0!important;overflow-x:hidden;overflow-y:auto;scrollbar-gutter:stable;font-family:var(--font-sans,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif);font-size:var(--text-base,14px);line-height:1.5;font-weight:400;font-style:normal;letter-spacing:normal;color:var(--color-token-foreground,inherit)}#cgp-panel *{font-family:inherit}.cgp-content{width:min(920px,calc(100% - 40px));max-width:none;margin:0 auto;padding:64px 0 48px}#cgp-panel .cgp-title{font-size:24px;line-height:1.25;font-weight:400;font-style:normal;letter-spacing:normal;margin:0 0 4px}#cgp-panel .cgp-subtitle{max-width:none;font-size:14px;line-height:21px;font-weight:400;font-style:normal;letter-spacing:normal;margin:0 0 36px}#cgp-panel .cgp-section-title{font-size:var(--text-base,14px);line-height:1.5;font-weight:var(--font-weight-medium,500)}#cgp-panel .cgp-section-hint,#cgp-panel .cgp-note{font-size:var(--text-sm,13px);line-height:1.5}#cgp-panel .cgp-position{font-size:var(--text-xs,12px);line-height:1.5}#cgp-panel .cgp-card-model{font-size:var(--text-base,14px);line-height:1.5;font-weight:var(--font-weight-medium,500)}#cgp-panel .cgp-effort,#cgp-panel .cgp-add,#cgp-panel .cgp-actions button,#cgp-panel .cgp-search{font-size:var(--text-xs,12px);line-height:1.5}#cgp-panel .cgp-card-controls button{font-size:var(--text-xs,12px);line-height:1}#cgp-panel button{font-family:inherit;font-style:normal;letter-spacing:normal}";
document.head.appendChild(nativeCss);
const compactCss=document.createElement("style");
compactCss.textContent="#cgp-panel .cgp-content{width:calc(100% - 2 * var(--padding-panel,24px));max-width:48rem;padding:calc(var(--height-toolbar,46px) + var(--padding-panel,24px)) 0 40px}#cgp-panel .cgp-subtitle{max-width:600px;margin-bottom:28px}.cgp-section-head{gap:14px;margin-bottom:9px}.cgp-track-shell{border-radius:13px;padding:11px 11px 13px}.cgp-direction{gap:8px;margin:0 3px 8px;font-size:10px}.cgp-track{gap:8px;min-height:99px;padding:1px 1px 5px}.cgp-card{flex-basis:128px;min-width:128px;height:91px;border-radius:10px;padding:9px 10px}.cgp-card-top{margin-bottom:6px}.cgp-position{gap:4px}.cgp-grip{font-size:11px}.cgp-remove{width:19px;height:19px;border-radius:5px;font-size:14px}.cgp-card-model{font-size:13px}.cgp-effort{margin-top:3px;padding:2px 6px;font-size:10px}.cgp-card-controls{right:7px;bottom:6px;gap:1px}.cgp-card-controls button{width:20px;height:19px;border-radius:5px}.cgp-available{margin-top:22px}.cgp-search{height:31px;border-radius:8px;padding:0 10px;margin-bottom:8px;font-size:11px}.cgp-available-box{gap:6px;padding:9px;border-radius:11px;min-height:43px}.cgp-add{gap:5px;height:27px;border-radius:7px;padding:0 8px}.cgp-add-plus{font-size:14px}.cgp-empty{padding:3px}.cgp-footer{gap:14px;margin-top:19px}.cgp-actions{gap:6px}.cgp-actions button{height:31px;border-radius:8px;padding:0 11px}.cgp-actions .cgp-save{padding:0 14px}@media(max-width:760px){#cgp-panel .cgp-content{width:calc(100% - 2 * var(--padding-panel,24px));padding-top:calc(var(--height-toolbar,46px) + var(--padding-panel,24px))}.cgp-footer{align-items:flex-end;flex-direction:column}.cgp-note{align-self:flex-start}}";
document.head.appendChild(compactCss);
let panel=null,state=null,nativeSelection=[],settingsSidebar=null,sidebarWidth=0;
const load=()=>{try{const v=JSON.parse(localStorage.getItem(KEY)||\"null\");if(Array.isArray(v)){const map=new Map(v.map(x=>[x.id,x]));return DEFAULTS.map(x=>({...x,enabled:map.has(x.id)?map.get(x.id).enabled!==false:x.enabled})).sort((a,b)=>{const ai=v.findIndex(x=>x.id===a.id),bi=v.findIndex(x=>x.id===b.id);return(ai<0?999:ai)-(bi<0?999:bi)})}}catch{}return DEFAULTS.map(x=>({...x}))};
const restoreNativeSelection=()=>{for(const [element,style] of nativeSelection){if(style==null)element.removeAttribute(\"style\");else element.setAttribute(\"style\",style)}nativeSelection=[]};
const close=()=>{panel?.remove();panel=null;restoreNativeSelection();document.querySelector(\"#cgp-tab\")?.setAttribute(\"data-active\",\"false\")};
const render=()=>{if(!panel)return;const track=panel.querySelector(\"#cgp-track\"),availableBox=panel.querySelector(\"#cgp-available-box\"),active=state.filter(item=>item.enabled),inactive=state.filter(item=>!item.enabled);track.textContent=\"\";availableBox.textContent=\"\";panel.querySelector(\"#cgp-count\").textContent=\`\${active.length} points\`;active.forEach((item,activeIndex)=>{const [model,effort]=item.label.split(\" — \"),stateIndex=state.indexOf(item),card=document.createElement(\"article\");card.className=\"cgp-card\";card.draggable=true;card.dataset.id=item.id;card.innerHTML=\`<div class=\"cgp-card-top\"><span class=\"cgp-position\"><span class=\"cgp-grip\">•••</span> \${activeIndex+1}</span><button class=\"cgp-remove\" aria-label=\"Remove \${item.label}\" title=\"Move to available\" \${active.length===1?\"disabled\":\"\"}>×</button></div><div class=\"cgp-card-model\">\${model}</div><span class=\"cgp-effort\">\${effort}</span><div class=\"cgp-card-controls\"><button class=\"cgp-left\" aria-label=\"Move \${item.label} left\" \${activeIndex===0?\"disabled\":\"\"}>←</button><button class=\"cgp-right\" aria-label=\"Move \${item.label} right\" \${activeIndex===active.length-1?\"disabled\":\"\"}>→</button></div>\`;card.ondragstart=event=>{event.dataTransfer.setData(\"text/plain\",item.id);event.dataTransfer.effectAllowed=\"move\";card.classList.add(\"cgp-dragging\")};card.ondragend=()=>{document.querySelectorAll(\".cgp-card\").forEach(node=>node.classList.remove(\"cgp-dragging\",\"cgp-drop\"))};card.ondragover=event=>{event.preventDefault();event.dataTransfer.dropEffect=\"move\";card.classList.add(\"cgp-drop\")};card.ondragleave=()=>card.classList.remove(\"cgp-drop\");card.ondrop=event=>{event.preventDefault();const sourceId=event.dataTransfer.getData(\"text/plain\"),from=state.findIndex(entry=>entry.id===sourceId),to=state.findIndex(entry=>entry.id===item.id);if(from>=0&&to>=0&&from!==to){const [moved]=state.splice(from,1);state.splice(to,0,moved)}render()};card.querySelector(\".cgp-remove\").onclick=()=>{item.enabled=false;render()};const move=delta=>{const other=active[activeIndex+delta];if(!other)return;const otherIndex=state.indexOf(other);[state[stateIndex],state[otherIndex]]=[state[otherIndex],state[stateIndex]];render()};card.querySelector(\".cgp-left\").onclick=()=>move(-1);card.querySelector(\".cgp-right\").onclick=()=>move(1);track.appendChild(card)});const searchEl=panel.querySelector(\"#cgp-available-search\"),query=(searchEl?.value||\"\").trim().toLowerCase(),filtered=query?inactive.filter(item=>item.label.toLowerCase().includes(query)):inactive;if(!inactive.length){availableBox.innerHTML=\"<span class=\\\"cgp-empty\\\">All points are currently on the slider.</span>\"}else if(!filtered.length){availableBox.innerHTML=\"<span class=\\\"cgp-empty\\\">No matching points found.</span>\"}else filtered.forEach(item=>{const button=document.createElement(\"button\");button.className=\"cgp-add\";button.innerHTML=\`<span class=\"cgp-add-plus\">+</span><span>\${item.label}</span>\`;button.onclick=()=>{item.enabled=true;render()};availableBox.appendChild(button)})};
const paneStyle=tab=>{let node=tab,sidebar=null;while(node&&node!==document.body){const r=node.getBoundingClientRect();if(r.width>=220&&r.width<=480&&r.height>innerHeight*.7){sidebar=node;break}node=node.parentElement}const left=Math.round(sidebar?.getBoundingClientRect().right||Math.min(380,innerWidth*.25));let sample=document.elementFromPoint(Math.min(left+80,innerWidth-1),Math.min(240,innerHeight-1));let bg=\"\";while(sample&&sample!==document.documentElement){const c=getComputedStyle(sample).backgroundColor;if(c&&c!==\"rgba(0, 0, 0, 0)\"&&c!==\"transparent\"){bg=c;break}sample=sample.parentElement}return{left,background:bg||getComputedStyle(document.body).backgroundColor||\"#fff\",color:getComputedStyle(tab).color}};
const findSettingsSidebar=tab=>{let node=tab;while(node&&node!==document.body){const rect=node.getBoundingClientRect();if(rect.width>=220&&rect.width<=480&&rect.height>innerHeight*.7)return node;node=node.parentElement}return null};
const setMetric=(name,value)=>{if(value)document.documentElement.style.setProperty(name,value)};
const findSettingsContent=tab=>{const sidebar=tab?.closest?.(".app-shell-left-panel")||findSettingsSidebar(tab);if(!sidebar)return null;let shell=sidebar.parentElement;while(shell&&shell!==document.body){const sidebarRect=sidebar.getBoundingClientRect();const content=[...shell.children].find(child=>{if(child===sidebar||child.contains(sidebar))return false;const rect=child.getBoundingClientRect();return rect.width>240&&rect.height>innerHeight*.7&&rect.left>=sidebarRect.right-2});if(content)return content;shell=shell.parentElement}return null};
const muteNativeSelection=(tab,left)=>{nativeSelection=[];for(const element of document.querySelectorAll("a,button,[role=button]")){if(element===tab)continue;const rect=element.getBoundingClientRect();if(rect.right>left+2||rect.width<80)continue;const background=getComputedStyle(element).backgroundColor;if(!background||background==="transparent"||background==="rgba(0, 0, 0, 0)")continue;nativeSelection.push([element,element.getAttribute("style")]);element.style.setProperty("background-color","transparent","important")}};
const open=()=>{close();state=load();const tab=document.querySelector(\"#cgp-tab\"),look=paneStyle(tab);muteNativeSelection(tab,look.left);panel=document.createElement(\"section\");panel.id=\"cgp-panel\";panel.style.left=look.left+\"px\";panel.style.backgroundColor=look.background;panel.style.color=look.color;panel.innerHTML=\`<div class=\"cgp-content\"><h1 class=\"cgp-title\">Shape your model slider</h1><p class=\"cgp-subtitle\">Build the exact sequence you want in the composer. Drag points along the track or use the arrow controls—the order below maps directly from left to right.</p><div class=\"cgp-section-head\"><h2 class=\"cgp-section-title\">Active slider</h2><span id=\"cgp-count\" class=\"cgp-section-hint\"></span></div><div class=\"cgp-track-shell\"><div class=\"cgp-direction\"><span>Left</span><span class=\"cgp-direction-line\"></span><span>Right</span></div><div id=\"cgp-track\" class=\"cgp-track\"></div></div><section class=\"cgp-available\"><div class=\"cgp-section-head\"><h2 class=\"cgp-section-title\">Available points</h2><span class=\"cgp-section-hint\">Select + to add a point</span></div><input id=\"cgp-available-search\" class=\"cgp-search\" type=\"search\" placeholder=\"Search models…\" autocomplete=\"off\" spellcheck=\"false\" /><div id=\"cgp-available-box\" class=\"cgp-available-box\"></div></section><div class=\"cgp-footer\"><span id=\"cgp-note\" class=\"cgp-note\">Changes apply live when you reopen the model picker</span><div class=\"cgp-actions\"><button id=\"cgp-reset\">Reset</button><button id=\"cgp-save\" class=\"cgp-save\">Apply changes</button></div></div></div>\`;(findSettingsContent(tab)||document.body).appendChild(panel);tab?.setAttribute(\"data-active\",\"true\");panel.querySelector(\"#cgp-reset\").onclick=()=>{state=DEFAULTS.map(x=>({...x}));render()};panel.querySelector(\"#cgp-save\").onclick=()=>{if(!state.some(x=>x.enabled)){alert(\"Add at least one point to the slider.\");return}const saved=state.map(({id,enabled})=>({id,enabled}));localStorage.setItem(KEY,JSON.stringify(saved));try{const channel=new BroadcastChannel(\"chatgpt-patcher.slider-live\");channel.postMessage(saved);setTimeout(()=>channel.close(),250)}catch{}panel.querySelector(\"#cgp-save\").textContent=\"Applied\";panel.querySelector(\"#cgp-note\").textContent=\"Applied live · reopen the model picker to see the new sequence\"};panel.querySelector(\"#cgp-available-search\").oninput=()=>render();render()};
const install=()=>{if(document.querySelector(\"#cgp-tab\"))return;const controls=[...document.querySelectorAll(\"a,button,[role=button]\")];const exact=t=>controls.find(e=>(e.textContent||\"\").replace(/\\s+/g,\" \").trim().toLowerCase()===t);const general=exact(\"general\"),appearance=exact(\"appearance\"),account=exact(\"account\");if(!general||!appearance||!account){if(panel)close();return}const button=appearance.cloneNode(true);button.id=\"cgp-tab\";button.removeAttribute(\"href\");button.removeAttribute(\"aria-current\");const icon=button.querySelector(\"svg\");if(icon){icon.setAttribute(\"viewBox\",\"0 0 24 24\");icon.setAttribute(\"fill\",\"none\");icon.setAttribute(\"stroke\",\"currentColor\");icon.setAttribute(\"stroke-width\",\"1.8\");icon.setAttribute(\"stroke-linecap\",\"round\");icon.innerHTML=\"<path d=\\\"M4 7h10M18 7h2M4 12h2M10 12h10M4 17h7M15 17h5\\\"/><circle cx=\\\"16\\\" cy=\\\"7\\\" r=\\\"2\\\"/><circle cx=\\\"8\\\" cy=\\\"12\\\" r=\\\"2\\\"/><circle cx=\\\"13\\\" cy=\\\"17\\\" r=\\\"2\\\"/>\"}const walker=document.createTreeWalker(button,NodeFilter.SHOW_TEXT);let textNode;while(textNode=walker.nextNode())if(textNode.nodeValue.trim().toLowerCase()===\"appearance\"){textNode.nodeValue=textNode.nodeValue.replace(/appearance/i,\"Model slider\");break}button.onclick=e=>{e.preventDefault();e.stopPropagation();open()};account.insertAdjacentElement(\"afterend\",button)};
const syncSettingsLayout=()=>{};
addEventListener(\"resize\",syncSettingsLayout);
new MutationObserver(install).observe(document.documentElement,{subtree:true,childList:true});document.addEventListener(\"click\",e=>{if(panel&&!e.target.closest?.(\"#cgp-panel,#cgp-tab\")&&e.clientX<panel.getBoundingClientRect().left)close()},true);addEventListener(\"popstate\",install);setInterval(install,1500);install();
})();`;
const liveArrayNames = [...new Set(matches.map(match => match.varName))];
const liveBootstrap = `
;(()=>{
if(globalThis.__chatgptPatcherLiveSliderInstalled)return;
globalThis.__chatgptPatcherLiveSliderInstalled=true;
const defaults=${JSON.stringify(defaultEntries)};
const getArrays=()=>[${liveArrayNames.join(",")}].filter(Array.isArray);
const apply=order=>{if(!Array.isArray(order))return;const byId=new Map(defaults.map(entry=>[entry.id,entry]));const next=order.filter(entry=>entry&&entry.enabled!==false&&byId.has(entry.id)).map(entry=>byId.get(entry.id));if(!next.length)return;for(const array of getArrays())array.splice(0,array.length,...next)};
try{const channel=new BroadcastChannel("chatgpt-patcher.slider-live");channel.onmessage=event=>apply(event.data);globalThis.__chatgptPatcherLiveSliderChannel=channel}catch{}
addEventListener("storage",event=>{if(event.key===KEY&&event.newValue)try{apply(JSON.parse(event.newValue))}catch{}});
})();`;
content += liveBootstrap + settingsBootstrap;

fs.writeFileSync(targetFile, content);
const settingsFiles = jsFiles.filter(file =>
    file !== targetFile &&
    path.basename(file).toLowerCase().includes("settings") &&
    !path.basename(file).toLowerCase().includes("worker")
);
for (const settingsFile of settingsFiles) {
    fs.appendFileSync(settingsFile, settingsBootstrap);
}

// Parse every modified bundle before repacking. This catches offset mistakes
// and malformed injected JavaScript before an app can be published.
const {spawnSync} = require("child_process");
for (const modifiedFile of [targetFile, ...settingsFiles]) {
    const syntaxCheck = spawnSync(process.execPath, ["--check", modifiedFile], {encoding:"utf8"});
    if (syntaxCheck.status !== 0) {
        console.error("ERROR: JavaScript syntax check failed for " + path.basename(modifiedFile));
        console.error((syntaxCheck.stderr || syntaxCheck.stdout || "Unknown parse error").trim());
        process.exit(1);
    }
}
console.log("");
console.log("  Done. Replaced " + matches.length + " array(s).");
console.log("  Installed settings bootstrap in " + settingsFiles.length + " settings bundle(s).");
console.log("  JavaScript syntax check passed for all modified bundles.");

// Output the target file path for verification step
console.log("TARGET_FILE=" + targetFile);
' "$EXTRACTED_DIR" "$SLIDER_POINTS_STR" "$DEFAULT_SLIDER_POINT" "$SLIDER_STORAGE_KEY" "$SCRIPT_DIR"); then
    echo ""
    echo "ERROR: Failed to find or replace slider arrays."
    echo "$PATCH_RESULT"
    exit 1
fi

echo "$PATCH_RESULT"
echo ""
else
    echo "Step 3–4: Custom model slider not selected; skipping slider transforms."
    echo ""
fi

if has_feature "hide-profile-menu-items"; then
    HIDE_MENU_PATCHER="$SCRIPT_DIR/patch-hide-profile-menu.js"
    if [ ! -f "$HIDE_MENU_PATCHER" ]; then
        echo "ERROR: Hide-profile-menu patcher is missing: $HIDE_MENU_PATCHER"
        exit 1
    fi
    echo "Step 4b: Hiding Show pet and Invite a friend from the profile dropdown..."
    if ! HIDE_MENU_RESULT=$("$NODE_BIN" "$HIDE_MENU_PATCHER" "$EXTRACTED_DIR"); then
        echo ""
        echo "ERROR: Failed to hide profile menu items."
        echo "$HIDE_MENU_RESULT"
        exit 1
    fi
    echo "$HIDE_MENU_RESULT"
    echo ""
fi

# Step 5: Patch the development banner in index.html
echo "Step 5: Patching development banner in index.html..."

INDEX_HTML="$EXTRACTED_DIR/webview/index.html"

if ! BANNER_RESULT=$("$NODE_BIN" -e '
const fs = require("fs");
const indexPath = process.argv[1];

let html = fs.readFileSync(indexPath, "utf8");

// Pure CSS toggleable banner — no JavaScript needed, immune to CSP.
// Uses a hidden checkbox + label pattern:
//   - Clicking the label (banner) toggles the checkbox
//   - CSS :checked state hides/shows the banner
//   - A small hint text appears when hidden so you can click to show it again
const newBanner = `<input type="checkbox" id="dev-banner-toggle" checked style="display:none">
    <label for="dev-banner-toggle" id="codex-modification-banner"
      style="position: fixed; top: 40px; left: 50%; transform: translateX(-50%); z-index: 2147483647; padding: 8px 14px; border: 1px solid rgba(255, 165, 0, 0.4); border-radius: 999px; background: rgba(24, 24, 27, 0.92); color: #ffb84d; font: 600 13px -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 4px 18px rgba(0, 0, 0, 0.24); cursor: pointer; user-select: none; transition: opacity 0.2s ease; -webkit-app-region: no-drag;"
    >Development Build</label>
    <label for="dev-banner-toggle" id="dev-banner-hint"
      style="position: fixed; right: 12px; bottom: 12px; z-index: 2147483647; padding: 4px 8px; border: 1px solid rgba(255, 165, 0, 0.3); border-radius: 6px; background: rgba(24, 24, 27, 0.85); color: rgba(255, 184, 77, 0.7); font: 500 11px -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer; user-select: none; transition: opacity 0.2s ease; -webkit-app-region: no-drag;"
    >Dev</label>
    <style>
      #dev-banner-toggle:checked ~ #codex-modification-banner { opacity: 1; pointer-events: auto; }
      #dev-banner-toggle:not(:checked) ~ #codex-modification-banner { opacity: 0; pointer-events: none; }
      #dev-banner-toggle:checked ~ #dev-banner-hint { opacity: 0; pointer-events: none; }
      #dev-banner-toggle:not(:checked) ~ #dev-banner-hint { opacity: 1; pointer-events: auto; }
    </style>`;

// Remove any existing banner block (previous patch, original "Hello" banner, or old script+style)
const existingBannerPattern = /<input[^>]*id="dev-banner-toggle"[^>]*>[\s\S]*?<\/style>|<div\s+id="codex-modification-banner"[\s\S]*?<\/div>(\s*<script[\s\S]*?<\/script>)?(\s*<style>[\s\S]*?<\/style>)?/;

if (existingBannerPattern.test(html)) {
    html = html.replace(existingBannerPattern, newBanner);
} else if (html.includes("</body>")) {
    html = html.replace("</body>", newBanner + "\n  </body>");
} else {
    console.error("ERROR: Could not find </body> tag or existing banner in index.html.");
    process.exit(1);
}

fs.writeFileSync(indexPath, html);
console.log("  Patched index.html with pure-CSS toggleable Development Build banner.");
' "$INDEX_HTML"); then
    echo ""
    echo "ERROR: Failed to patch development banner."
    echo "$BANNER_RESULT"
    exit 1
fi

echo "$BANNER_RESULT"
echo ""

# Step 6: Repack to a temporary file next to app.asar. Keeping it in the same
# directory lets the final mv replace the target atomically on the same volume.
PACKED_ASAR="$(mktemp "${ASAR_PATH}.patched.XXXXXX")"
rm -f "$PACKED_ASAR"

echo "Step 6: Repacking a temporary app.asar..."
"$NPX_BIN" --yes @electron/asar pack "$EXTRACTED_DIR" "$PACKED_ASAR"
echo "  Packed temporary file: $PACKED_ASAR"
echo ""

# Step 7: Verify the temporary archive before replacing the app's app.asar
echo "Step 7: Verifying..."
VERIFY_DIR="$WORK_DIR/verify"
"$NPX_BIN" --yes @electron/asar extract "$PACKED_ASAR" "$VERIFY_DIR"

VERIFY_WANT_SLIDER=0
VERIFY_WANT_HIDE_MENU=0
has_feature "custom-model-slider" && VERIFY_WANT_SLIDER=1
has_feature "hide-profile-menu-items" && VERIFY_WANT_HIDE_MENU=1

VERIFY_RESULT=$("$NODE_BIN" -e '
const fs = require("fs");
const path = require("path");
const verifyDir = process.argv[1];
const defaultSliderPoint = process.argv[2];
const wantSlider = process.argv[4] === "1";
const wantHideMenu = process.argv[5] === "1";

function findJsFiles(dir) {
    let results = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            results = results.concat(findJsFiles(fullPath));
        } else if (entry.name.endsWith(".js")) {
            results.push(fullPath);
        }
    }
    return results;
}

const assetsDir = path.join(verifyDir, "webview", "assets");
const jsFiles = findJsFiles(assetsDir);

let sliderOk = false;
let settingsOk = false;
let liveUpdateOk = false;
let defaultPointOk = false;
let hideMenuOk = false;
for (const file of jsFiles) {
    const content = fs.readFileSync(file, "utf8");
    const expectedIds = process.argv[3].split("\n").filter(Boolean);
    if (expectedIds.length && expectedIds.every(point => content.includes(point))) {
        sliderOk = true;
    }
    if (content.includes("__chatgptPatcherSettingsInstalled") && content.includes("chatgpt-patcher.slider-order")) {
        settingsOk = true;
    }
    if (content.includes("__chatgptPatcherLiveSliderInstalled") && content.includes("chatgpt-patcher.slider-live")) {
        liveUpdateOk = true;
    }
    if (content.includes(`e.id===\`${defaultSliderPoint}\``)) {
        defaultPointOk = true;
    }
    if (content.includes("__chatgptPatcherHideProfileMenuInstalled")) {
        hideMenuOk = true;
    }
}

// Check banner in index.html
const indexPath = path.join(verifyDir, "webview", "index.html");
let bannerOk = false;
if (fs.existsSync(indexPath)) {
    const html = fs.readFileSync(indexPath, "utf8");
    bannerOk = html.includes("Development Build") && html.includes("dev-banner-toggle");
}

const checks = [];
let ok = bannerOk;
checks.push(bannerOk ? "banner" : "banner-missing");

if (wantSlider) {
    const sliderPass = sliderOk && settingsOk && liveUpdateOk && defaultPointOk;
    ok = ok && sliderPass;
    checks.push(sliderPass ? "slider+settings+live-update+default-point" : "slider-incomplete");
}

if (wantHideMenu) {
    ok = ok && hideMenuOk;
    checks.push(hideMenuOk ? "hide-profile-menu" : "hide-profile-menu-missing");
}

console.log((ok ? "OK:" : "FAIL:") + checks.join("+"));
' "$VERIFY_DIR" "$DEFAULT_SLIDER_POINT" "$SLIDER_POINTS_STR" "$VERIFY_WANT_SLIDER" "$VERIFY_WANT_HIDE_MENU")

if [[ "$VERIFY_RESULT" == "OK:"* ]]; then
    echo "  Verification OK: ${VERIFY_RESULT#OK:}"
else
    echo "  ERROR: Verification failed — $VERIFY_RESULT"
    echo "  Original app.asar was left unchanged."
    exit 1
fi
echo ""

# Electron verifies the SHA-256 of the raw ASAR header at launch. Recalculate
# the header hash from the temporary archive before publishing it.
ASAR_HEADER_HASH=$("$NODE_BIN" -e '
const fs = require("fs");
const crypto = require("crypto");
const archivePath = process.argv[1];
const fd = fs.openSync(archivePath, "r");
try {
    const preamble = Buffer.alloc(8);
    if (fs.readSync(fd, preamble, 0, preamble.length, 0) !== preamble.length) {
        throw new Error("Unable to read ASAR header size");
    }
    const pickleSize = preamble.readUInt32LE(4);
    const pickle = Buffer.alloc(pickleSize);
    if (fs.readSync(fd, pickle, 0, pickle.length, 8) !== pickle.length) {
        throw new Error("Unable to read ASAR header");
    }
    const headerLength = pickle.readUInt32LE(4);
    const header = pickle.subarray(8, 8 + headerLength);
    process.stdout.write(crypto.createHash("sha256").update(header).digest("hex"));
} finally {
    fs.closeSync(fd);
}
' "$PACKED_ASAR")

if [ -z "$ASAR_HEADER_HASH" ]; then
    echo "ERROR: Could not calculate the ASAR integrity hash."
    exit 1
fi

# Only replace the original after a successful verification. This is an atomic
# rename because the temporary archive lives alongside the target file.
mv -f "$PACKED_ASAR" "$ASAR_PATH"
PACKED_ASAR=""
echo "  Replaced: $ASAR_PATH"
echo ""

# Step 8: Update Electron's ASAR integrity metadata. The slash is part of the
# plist key (Resources/app.asar), so PlistBuddy is used instead of plutil's
# dot-delimited key-path syntax.
echo "Step 8: Updating Electron ASAR integrity metadata..."
if ! /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $ASAR_HEADER_HASH" "$INFO_PLIST"; then
    echo "ERROR: Could not update ElectronAsarIntegrity in Info.plist."
    exit 1
fi
echo "  Updated hash: $ASAR_HEADER_HASH"
echo ""

if has_feature "opencodego-provider"; then
    if [ ! -x "$PROVIDER_INSTALLER" ]; then
        echo "ERROR: OpenCode Go provider installer is missing: $PROVIDER_INSTALLER"
        exit 1
    fi
    echo "Embedding the isolated OpenCode Go provider runtime..."
    "$PROVIDER_INSTALLER" "$APP_PATH"
    echo ""
fi

# Step 9: Modifying app.asar, Info.plist, or the Codex launcher invalidates
# OpenAI's signature.
# Apply a local ad-hoc signature so Finder can launch this generated copy.
# Do not use --deep here: nested helpers keep their original signatures.
echo "Step 9: Signing the patched app for local launch..."
if ! /usr/bin/codesign --force --sign - "$APP_PATH"; then
    echo "ERROR: Could not sign the patched app copy."
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict "$APP_PATH"; then
    echo "ERROR: The patched app copy did not pass signature verification."
    exit 1
fi
echo "  Signed and verified."
echo ""

# Step 10: Clear quarantine inherited from a downloaded source copy.
echo "Step 10: Clearing inherited quarantine metadata from the patched copy..."
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
echo "  Cleared."
echo ""

if has_feature "custom-model-slider"; then
    "$NODE_BIN" "$SCRIPT_DIR/patch-labels.js" catalog "$ACTIVE_SLIDER_POINTS_STR" "$AVAILABLE_SLIDER_POINTS_STR"
    echo ""
fi
if [ "$SKIP_BACKUP" != "1" ]; then
    echo "Backup of original: $ASAR_BACKUP"
    echo "Info.plist backup:   $INFO_PLIST_BACKUP"
    echo ""
    echo "To restore the original:"
    echo "  cp \"$ASAR_BACKUP\" \"$ASAR_PATH\""
    echo "  cp \"$INFO_PLIST_BACKUP\" \"$INFO_PLIST\""
fi
