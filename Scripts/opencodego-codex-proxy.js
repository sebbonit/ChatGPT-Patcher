#!/usr/bin/env node
"use strict";

const fs = require("fs");
const {spawn} = require("child_process");

const separator = process.argv.indexOf("--");
const realCodex = process.argv[2];
const catalogPath = process.argv[3];
const codexArgs = process.argv.slice(separator + 1);
if (!realCodex || !catalogPath || separator < 0) process.exit(2);

const openCodeModels = new Set(JSON.parse(fs.readFileSync(catalogPath, "utf8")).models.map(model => model.slug));
const child = spawn(realCodex, codexArgs, {stdio: ["pipe", "inherit", "inherit"], env: process.env});

let buffered = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  buffered += chunk;
  for (;;) {
    const newline = buffered.indexOf("\n");
    if (newline < 0) break;
      const line = buffered.slice(0, newline);
      buffered = buffered.slice(newline + 1);
      let output = line;
      try {
        const message = JSON.parse(line);
        const method = message.method;
        const model = message.params?.model;
        // Provider selection is attached to the thread by Codex. Set it on
        // every request that can establish or change model context so a GPT
        // model cannot accidentally be sent through the OpenCode adapter.
        if (["thread/start", "thread/resume", "thread/fork", "turn/start"].includes(method) && model) {
          message.params.modelProvider = openCodeModels.has(model) ? "opencodego" : "openai";
          output = JSON.stringify(message);
        } else if (method === "thread/start" && message.params) {
          // A model-less new thread must use the stock provider, never the
          // optional OpenCode provider merely because it is configured.
          message.params.modelProvider = "openai";
          output = JSON.stringify(message);
        }
      } catch {}
      child.stdin.write(output + "\n");
  }
});
process.stdin.on("end", () => child.stdin.end(buffered));
child.on("exit", (code, signal) => signal ? process.kill(process.pid, signal) : process.exit(code ?? 1));
