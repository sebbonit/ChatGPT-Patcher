#!/usr/bin/env node
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

if (process.env.OPENCODE_GO_API_KEY) {
  process.stdout.write(process.env.OPENCODE_GO_API_KEY.trim());
  process.exit(0);
}

const candidates = [
  process.env.XDG_DATA_HOME && path.join(process.env.XDG_DATA_HOME, "opencode", "auth.json"),
  path.join(os.homedir(), ".local", "share", "opencode", "auth.json"),
  path.join(os.homedir(), "Library", "Application Support", "opencode", "auth.json"),
].filter(Boolean);

for (const candidate of candidates) {
  try {
    const entry = JSON.parse(fs.readFileSync(candidate, "utf8"))["opencode-go"];
    const key = entry?.key || entry?.token || entry?.apiKey;
    if (typeof key === "string" && key.trim()) {
      process.stdout.write(key.trim());
      process.exit(0);
    }
  } catch {}
}

process.stderr.write("OpenCode Go API key not found. Run `opencode auth login --provider opencode-go` or set OPENCODE_GO_API_KEY.\n");
process.exit(1);

