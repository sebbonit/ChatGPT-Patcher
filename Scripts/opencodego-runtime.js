#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const {spawn} = require("child_process");

const [sourceConfig, runtimeDir, providerDir, nodeBin] = process.argv.slice(2);
if (!sourceConfig || !runtimeDir || !providerDir || !nodeBin) {
  console.error("OpenCode Go runtime received incomplete launch arguments.");
  process.exit(1);
}

fs.mkdirSync(runtimeDir, {recursive: true});

// Build a process-local catalog without modifying the user's Codex config or
// models cache. OpenAI remains the default provider; the stdio proxy selects
// opencodego only for threads using one of the added model IDs.
const sourceHome = path.dirname(sourceConfig);
const stockCatalogPath = path.join(sourceHome, "models_cache.json");
const openCodeCatalog = JSON.parse(fs.readFileSync(path.join(providerDir, "opencodego-models.json"), "utf8"));
const stockCatalog = fs.existsSync(stockCatalogPath) ? JSON.parse(fs.readFileSync(stockCatalogPath, "utf8")) : {models: []};
const sliderOpenAIModels = new Set(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]);
const stockModels = (stockCatalog.models ?? []).filter(model => sliderOpenAIModels.has(model.slug));
const openCodeModels = openCodeCatalog.models.map((model, index) => ({
  ...model,
  display_name: `OpenCode Go · ${model.display_name}`,
  priority: stockModels.length + index + 1,
}));
const combinedCatalogPath = path.join(runtimeDir, "combined-models.json");
fs.writeFileSync(combinedCatalogPath, JSON.stringify({
  fetched_at: new Date().toISOString(),
  client_version: stockCatalog.client_version ?? "chatgpt-patcher",
  models: [...stockModels, ...openCodeModels],
}, null, 2));

async function adapterIsReady() {
  try { return (await fetch("http://127.0.0.1:42429/health")).ok; }
  catch { return false; }
}

(async () => {
  if (await adapterIsReady()) return;
  const log = fs.openSync(path.join(runtimeDir, "opencodego-adapter.log"), "a");
  const child = spawn(nodeBin, [path.join(providerDir, "opencodego-adapter.js")], {
    detached: true,
    stdio: ["ignore", log, log],
    env: {...process.env, OPENCODEGO_MODEL_CATALOG: path.join(providerDir, "opencodego-models.json")},
  });
  child.unref();
  for (let attempt = 0; attempt < 20; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 100));
    if (await adapterIsReady()) return;
  }
  throw new Error("OpenCode Go adapter did not become ready.");
})().catch(error => {
  console.error(`OpenCode Go runtime error: ${error.message}`);
  process.exit(1);
});
