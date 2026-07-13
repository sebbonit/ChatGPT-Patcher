# ChatGPT Patcher (native launcher)

Double-click [`../launch-chatgpt-patcher.command`](../launch-chatgpt-patcher.command), or run it from Terminal. It builds and opens the native macOS app without requiring Xcode.

For full documentation — features, model catalog, OpenCode Go setup, CLI usage, and troubleshooting — see the [project README](../../README.md).

## Quick workflow

1. **Select source** — choose the original Codex app (`com.openai.codex`). The original is never modified.
2. **Choose output** — pick where to save `ChatGPT (Patched).app`.
3. **Select features** — enable **Custom Model Slider & Configuration** and/or **OpenCode Go Provider & Models**.
4. **Patch & verify** — the patcher stages a copy, applies changes, verifies them, signs the bundle, and publishes the result.

Quit Codex before patching or launching the patched copy.
