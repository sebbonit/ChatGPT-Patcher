#!/usr/bin/env node
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

const host = process.env.OPENCODEGO_ADAPTER_HOST || "127.0.0.1";
const port = Number(process.env.OPENCODEGO_ADAPTER_PORT || 42429);
const upstreamBase = (process.env.OPENCODEGO_UPSTREAM_BASE_URL || "https://opencode.ai/zen/go/v1").replace(/\/$/, "");
const catalogPath = process.env.OPENCODEGO_MODEL_CATALOG || path.join(__dirname, "opencodego-models.json");
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const modelBySlug = new Map(catalog.models.map(model => [model.slug, model]));

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {"content-type": "application/json", "content-length": Buffer.byteLength(body)});
  res.end(body);
}

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map(part => {
    if (!part || typeof part !== "object") return "";
    if (["input_text", "output_text", "text"].includes(part.type)) return part.text || "";
    return "";
  }).join("");
}

function imageParts(content) {
  if (!Array.isArray(content)) return [];
  return content.flatMap(part => {
    if (!part || part.type !== "input_image") return [];
    const url = part.image_url || part.url;
    return url ? [{type: "image_url", image_url: {url}}] : [];
  });
}

function toChatMessages(body) {
  const messages = [];
  if (body.instructions) messages.push({role: "system", content: body.instructions});
  for (const item of body.input || []) {
    if (!item || typeof item !== "object") continue;
    if (item.type === "message") {
      const text = textFromContent(item.content);
      const images = imageParts(item.content);
      const content = images.length ? [...(text ? [{type: "text", text}] : []), ...images] : text;
      messages.push({role: item.role === "developer" ? "system" : item.role, content});
    } else if (item.type === "function_call") {
      messages.push({
        role: "assistant",
        content: "",
        reasoning_content: " ",
        tool_calls: [{id: item.call_id, type: "function", function: {name: item.name, arguments: item.arguments || "{}"}}],
      });
    } else if (item.type === "function_call_output") {
      messages.push({role: "tool", tool_call_id: item.call_id, content: textFromContent(item.output) || String(item.output || "")});
    }
  }
  return messages;
}

function toChatTools(tools) {
  return (tools || []).filter(tool => tool?.type === "function").map(tool => ({
    type: "function",
    function: {
      name: tool.name || tool.function?.name,
      description: tool.description || tool.function?.description,
      parameters: tool.parameters || tool.function?.parameters || {type: "object", properties: {}},
    },
  }));
}

function sse(res, event) {
  res.write(`data: ${JSON.stringify(event)}\n\n`);
}

function completedResponse(id, usage) {
  const input = usage?.prompt_tokens || 0;
  const output = usage?.completion_tokens || 0;
  return {
    id,
    usage: {
      input_tokens: input,
      input_tokens_details: {cached_tokens: usage?.prompt_tokens_details?.cached_tokens || 0},
      output_tokens: output,
      output_tokens_details: {reasoning_tokens: usage?.completion_tokens_details?.reasoning_tokens || 0},
      total_tokens: usage?.total_tokens || input + output,
    },
  };
}

async function proxyResponses(req, res, body) {
  const authorization = req.headers.authorization;
  if (!authorization) return json(res, 401, {error: {message: "OpenCode Go API key is missing."}});

  const model = modelBySlug.get(body.model);
  if (!model) {
    return json(res, 400, {
      error: {
        message: `Model ${body.model || "(missing)"} is not an OpenCode Go model. The request was routed to the OpenAI provider instead.`,
        type: "invalid_model",
      },
    });
  }

  const tools = toChatTools(body.tools);
  const upstreamBody = {
    model: body.model,
    messages: toChatMessages(body),
    stream: true,
    stream_options: {include_usage: true},
  };
  if (tools.length) {
    upstreamBody.tools = tools;
    upstreamBody.tool_choice = body.tool_choice || "auto";
    upstreamBody.parallel_tool_calls = body.parallel_tool_calls !== false;
  }
  const effort = body.reasoning?.effort;
  const supportedEfforts = new Set((model.supported_reasoning_levels || []).map(option => option.effort));
  if (effort && effort !== "none" && !supportedEfforts.has(effort)) {
    return json(res, 400, {
      error: {
        message: `Reasoning effort ${effort} is not supported for ${model.slug}. Supported values: ${[...supportedEfforts].join(", ") || "none"}.`,
        type: "invalid_reasoning_effort",
      },
    });
  }
  if (effort && effort !== "none") upstreamBody.reasoning_effort = effort === "max" ? "xhigh" : effort;

  let upstream;
  try {
    upstream = await fetch(`${upstreamBase}/chat/completions`, {
      method: "POST",
      headers: {
        authorization,
        "content-type": "application/json",
        "user-agent": "codex-opencodego-adapter/1.0",
      },
      body: JSON.stringify(upstreamBody),
      signal: AbortSignal.timeout(300000),
    });
  } catch (error) {
    return json(res, 502, {error: {message: `Could not reach OpenCode Go: ${error.message}`}});
  }

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text();
    res.writeHead(upstream.status, {"content-type": upstream.headers.get("content-type") || "application/json"});
    return res.end(detail);
  }

  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  const responseId = `resp_ocgo_${Date.now().toString(36)}`;
  sse(res, {type: "response.created", response: {id: responseId}});

  let buffer = "";
  let outputText = "";
  let messageAdded = false;
  let usage = null;
  const toolCalls = new Map();
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();

  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, {stream: true});
      const records = buffer.split(/\r?\n\r?\n/);
      buffer = records.pop() || "";
      for (const record of records) {
        for (const line of record.split(/\r?\n/)) {
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (!data || data === "[DONE]") continue;
          let chunk;
          try { chunk = JSON.parse(data); } catch { continue; }
          if (chunk.usage) usage = chunk.usage;
          const choice = chunk.choices?.[0];
          const delta = choice?.delta || {};
          if (typeof delta.content === "string" && delta.content) {
            if (!messageAdded) {
              messageAdded = true;
              sse(res, {type: "response.output_item.added", item: {type: "message", role: "assistant", id: `msg_${responseId}`, content: []}});
            }
            outputText += delta.content;
            sse(res, {type: "response.output_text.delta", delta: delta.content});
          }
          for (const call of delta.tool_calls || []) {
            const index = call.index || 0;
            const current = toolCalls.get(index) || {id: "", name: "", arguments: ""};
            if (call.id) current.id = call.id;
            if (call.function?.name) current.name += call.function.name;
            if (call.function?.arguments) current.arguments += call.function.arguments;
            toolCalls.set(index, current);
          }
        }
      }
    }

    if (outputText) {
      sse(res, {type: "response.output_item.done", item: {type: "message", role: "assistant", id: `msg_${responseId}`, content: [{type: "output_text", text: outputText}]}});
    }
    for (const [index, call] of toolCalls) {
      const callId = call.id || `call_ocgo_${index}_${Date.now().toString(36)}`;
      sse(res, {type: "response.output_item.done", item: {type: "function_call", call_id: callId, name: call.name, arguments: call.arguments || "{}"}});
    }
    sse(res, {type: "response.completed", response: completedResponse(responseId, usage)});
    res.end();
  } catch (error) {
    sse(res, {type: "response.failed", response: {error: {type: "adapter_error", message: error.message}}});
    res.end();
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") return json(res, 200, {ok: true, upstream: upstreamBase});
  if (req.method === "GET" && req.url === "/models") {
    return json(res, 200, catalog);
  }
  if (req.method !== "POST" || req.url !== "/responses") return json(res, 404, {error: {message: "Not found"}});
  let raw = "";
  req.setEncoding("utf8");
  for await (const chunk of req) raw += chunk;
  let body;
  try { body = JSON.parse(raw); } catch { return json(res, 400, {error: {message: "Invalid JSON"}}); }
  return proxyResponses(req, res, body);
});

server.listen(port, host, () => process.stdout.write(`OpenCode Go adapter listening on http://${host}:${port}\n`));
