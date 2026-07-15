# ChatGPT Patcher

**ChatGPT Patcher** is a macOS tool that patches the official **ChatGPT / Codex desktop app** with a **custom model slider**, optional **OpenCode Go models**, and a safe **patched copy** workflow — without modifying your original installation.

Customize the ChatGPT model picker on Mac, reorder reasoning-effort points, hide unused models, and build a verified `ChatGPT (Patched).app` you can launch from Finder.

![ChatGPT Patcher — select a source app, choose an output location, pick features, and build a verified patched copy](<Public/Screenshot 2026-07-14 at 14.57.17.png>)

Use the native **ChatGPT Patcher** app to pick a source app, choose where to save the patched copy, select features, and build a verified bundle you can launch from Finder.

```text
Original Codex app  →  staged copy  →  patch & verify  →  ChatGPT (Patched).app
     (unchanged)          (hidden)         (Node.js)            (your output)
```

---

## Quick start

**Requirements:** macOS, [Node.js](https://nodejs.org/) (including `npx`), and an unmodified Codex app.

1. Double-click [`Scripts/launch-chatgpt-patcher.command`](Scripts/launch-chatgpt-patcher.command), or run it from Terminal.
2. Choose the **original Codex app** as the source (the patcher auto-detects apps in common `Applications` folders).
3. Pick a **save location** — the default output name is `ChatGPT (Patched).app`.
4. Select one or more **features to patch**.
5. Click **Patch & verify**, then open the generated copy.

> **Quit Codex before patching or launching the patched copy.** Both apps share the same UI profile and history database; running them at the same time can cause conflicts.

The launcher builds the native UI with Swift (no Xcode required) and bundles all patch scripts inside the app.

---

## Features

| Feature | What it does |
| --- | --- |
| **Custom Model Slider & Configuration** | Replaces the composer model slider with a curated catalog, adds a **Model slider** settings tab, and lets you reorder, hide, and restore points. |
| **OpenCode Go Provider & Models** | Embeds a localhost Responses-to-Chat-Completions adapter and 20 third-party models as a **separate per-thread provider**, without changing your global `~/.codex` config. |

You can enable either feature alone or both together. At least one must be selected before patching.

---

### Custom Model Slider & Configuration

The model picker slider in Codex is replaced with a hand-picked set of GPT-5.6 points. A new **Model slider** tab appears in **Settings**, alongside General and Account.

<video src="Public/Screen%20Recording%202026-07-15%20at%2016.21.51.mov" controls width="732">
  <a href="Public/Screen%20Recording%202026-07-15%20at%2016.21.51.mov">Download screen recording</a> — composer model picker with the Faster ↔ Smarter slider.
</video>

![Codex Settings — Model slider tab for shaping the active sequence, searching available points, and applying changes live](<Public/Screenshot 2026-07-15 at 16.22.19.png>)

**Default active slider (left → right):**

| Model | Effort levels on slider |
| --- | --- |
| **5.6 Luna** | medium, high, xhigh, max |
| **5.6 Sol** | low, medium, high, xhigh, max |
| **5.6 Terra** | medium, high, xhigh *(available points only — add via Settings)* |

The default selected point when opening the picker is **5.6 Sol — medium**.

**Settings UI capabilities:**

- **Active slider** — drag cards left/right or use arrow controls to set the exact sequence shown in the composer.
- **Available points** — removed points stay here; click **+** to add them back. Use the **search field** to filter by model name or effort level.
- **Apply changes** — saves your layout to local storage and updates the running app live. Reopen the model picker to see the new sequence.
- **Reset** — restores the built-in default layout.

OpenAI remains the default provider. New GPT threads continue to use the built-in `openai` provider.

When the OpenCode Go feature is also enabled, its models are added to the **Available points** catalog but are **not** placed on the default slider track — you add only the ones you want.

**Reasoning effort by model (OpenCode catalog):**

- Most OpenCode models expose no effort choices.
- **GLM-5.2** — high, max
- **DeepSeek V4 Pro** — max

---

### OpenCode Go Provider & Models

Adds OpenCode Go as an isolated provider inside the patched app bundle. Your installed Codex app, terminal Codex, and `~/.codex/config.toml` are **never modified**.

**Included models (20):**

GLM-5, GLM-5.1, GLM-5.2, Kimi K2.5, Kimi K2.6, Kimi K2.7 Code, MiMo V2 Pro, MiMo V2 Omni, MiMo V2.5 Pro, MiMo V2.5, MiniMax M2.5, MiniMax M2.7, MiniMax M3, Qwen 3.5 Plus, Qwen 3.6 Plus, Qwen 3.7 Plus, Qwen 3.7 Max, DeepSeek V4 Pro, DeepSeek V4 Flash, HY3 Preview

**How it works:**

- A localhost adapter translates OpenAI Responses API calls to Chat Completions for OpenCode Go.
- The adapter starts on demand when the patched app's bundled Codex runtime needs it.
- The patched copy gets its own bundle identifier and Chromium data directory so it does not collide with a running stock app.
- Projects, chats, settings, and authentication from your normal Codex profile remain available.

**Authentication** is read from:

1. The `OPENCODE_GO_API_KEY` environment variable, or
2. The `opencode-go` entry created by `opencode auth login --provider opencode-go`

New threads started with an OpenCode model are routed to the separate `opencodego` provider.

---

### Development Build banner

When the model slider feature is enabled, the patcher also adds a toggleable **Development Build** banner at the top of the window.

- Click the banner to hide it.
- Click the small **Dev** hint (bottom-right) to show it again.

The banner uses pure CSS (no extra JavaScript), so it works regardless of content security policy.

---

## How patching works

The patcher never edits your source app. It always works on a disposable staging copy.

```mermaid
flowchart LR
    A[Select source app] --> B[Copy to staging bundle]
    B --> C[Extract app.asar]
    C --> D[Patch JavaScript bundles]
    D --> E[Patch index.html banner]
    E --> F[Repack & verify]
    F --> G[Update ASAR integrity hash]
    G --> H[Embed OpenCode runtime]
    H --> I[Sign & clear quarantine]
    I --> J[Publish to output path]
```

**Safety guarantees:**

- The original app bundle is never modified.
- Patches are verified (JavaScript syntax check, slider array presence, settings bootstrap, banner) before the output is published.
- The output replaces the previous patched copy only after verification succeeds.
- Electron's `ElectronAsarIntegrity` hash in `Info.plist` is updated so the app can launch.
- The patched copy is ad-hoc signed and quarantine metadata is cleared.

Use an **original, unmodified** Codex app as the source. An already-patched or ad-hoc-signed source can trigger Keychain identity prompts.

---

## Command-line usage

You can run the patch worker directly without the native UI:

```bash
# Patch the default local copy (ChatGPT-Hello.app in the project root)
./Scripts/patch-model-slider.sh

# Patch a specific app bundle
./Scripts/patch-model-slider.sh /path/to/Codex.app

# Enable only the model slider
PATCHER_FEATURES=custom-model-slider ./Scripts/patch-model-slider.sh /path/to/Codex.app

# Enable only OpenCode Go
PATCHER_FEATURES=opencodego-provider ./Scripts/patch-model-slider.sh /path/to/Codex.app

# Enable both features
PATCHER_FEATURES=custom-model-slider,opencodego-provider ./Scripts/patch-model-slider.sh /path/to/Codex.app
```

Re-run the patch script after every Codex app update to re-apply modifications. If OpenAI changes internal bundle structure or model names, the script exits without modifying anything and prints a warning.

---

## Project structure

```text
Scripts/
├── launch-chatgpt-patcher.command   # Double-click launcher
├── patch-model-slider.sh            # Core ASAR patch worker
├── install-opencodego-provider.sh   # Embeds OpenCode Go runtime
├── uninstall-opencodego-provider.sh # Restores original Codex launcher in a patched app
├── opencodego-*.js / .json / .sh    # OpenCode Go adapter, auth, models, runtime
└── ChatGPTPatcher/
    ├── ChatGPTPatcher.swift         # Native macOS UI
    ├── build-app.sh                 # Builds ChatGPT Patcher.app
    └── ChatGPT Patcher.app          # Self-contained patcher application
```

---

## After a Codex update

1. Quit Codex completely.
2. Re-run the patcher against the **new, unmodified** Codex app as the source.
3. Let it replace your existing `ChatGPT (Patched).app`.

Your model slider layout is stored in the app's local storage and persists across re-patches as long as the storage key namespace has not changed.

---

## Troubleshooting

| Issue | What to try |
| --- | --- |
| Patch fails with "Could not find slider arrays" | Codex was updated with a new bundle layout. Use the latest patcher scripts and an unmodified source app. |
| Keychain identity prompts on launch | Source app may already be patched or ad-hoc signed. Start from a fresh Codex install. |
| Patched app won't open | Ensure Node.js was available during patching. Re-run the patcher and check the log for verification errors. |
| OpenCode models don't respond | Confirm `OPENCODE_GO_API_KEY` or `opencode auth login --provider opencode-go` is configured. |
| Stock and patched apps conflict | Quit the stock app before opening the patched copy. |

To remove the OpenCode Go runtime from an already-patched app (without touching global config):

```bash
./Scripts/uninstall-opencodego-provider.sh /path/to/ChatGPT\ \(Patched\).app
```

---

## FAQ

### How do I customize the ChatGPT model slider on Mac?

Clone this repo, run [`Scripts/launch-chatgpt-patcher.command`](Scripts/launch-chatgpt-patcher.command), enable **Custom Model Slider & Configuration**, and build a patched copy. Then open **Settings → Model slider** in the patched app to reorder, hide, or restore model points.

### How do I add OpenCode Go models to Codex?

Enable **OpenCode Go Provider & Models** in the patcher, build your patched copy, and authenticate with `OPENCODE_GO_API_KEY` or `opencode auth login --provider opencode-go`. OpenCode models appear in the model picker as a separate per-thread provider.

### Is the original ChatGPT app modified?

No. The patcher always works on a staged copy. Your source app in `/Applications` stays untouched.

### Do I need to re-patch after a ChatGPT update?

Yes. Re-run the patcher against the new unmodified Codex app after each update to re-apply modifications.

### What models are on the default slider?

**5.6 Luna** (medium–max), **5.6 Sol** (low–max), and **5.6 Terra** (medium–xhigh, available to add via Settings).

---

## License & disclaimer

This project modifies a third-party application for personal use. It is not affiliated with or endorsed by OpenAI. Use at your own risk, and keep a backup of your original Codex app.
