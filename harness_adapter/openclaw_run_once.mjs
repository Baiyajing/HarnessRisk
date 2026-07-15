#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

function parseArgs(argv) {
  const out = {};
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--input") {
      out.input = argv[++index];
    } else if (arg === "--output") {
      out.output = argv[++index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!out.input || !out.output) {
    throw new Error("Usage: openclaw_run_once.mjs --input request.json --output result.json");
  }
  return out;
}

function safeStringify(value) {
  const seen = new WeakSet();
  return JSON.stringify(
    value,
    (key, current) => {
      if (typeof current === "bigint") {
        return current.toString();
      }
      if (typeof current === "function") {
        return `[Function ${current.name || "anonymous"}]`;
      }
      if (current instanceof Error) {
        return {
          name: current.name,
          message: current.message,
          stack: current.stack,
        };
      }
      if (current && typeof current === "object") {
        if (seen.has(current)) {
          return "[Circular]";
        }
        seen.add(current);
      }
      return current;
    },
    2,
  );
}

function payloadText(result) {
  const payloads = Array.isArray(result?.payloads) ? result.payloads : [];
  return payloads
    .map((payload) => String(payload?.text ?? "").trim())
    .filter(Boolean)
    .join("\n\n");
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function installGeminiFetchRateLimiter() {
  if (process.env.OPENCLAW_ADAPTER_GEMINI_DISABLE_RATE_LIMIT === "1") {
    return;
  }
  const rawLimit = process.env.OPENCLAW_ADAPTER_GEMINI_RATE_LIMIT_PER_MINUTE;
  if (!rawLimit) {
    return;
  }
  const limit = Number.parseInt(rawLimit, 10);
  const windowSeconds = Number.parseInt(
    process.env.OPENCLAW_ADAPTER_GEMINI_RATE_WINDOW_SECONDS || "60",
    10,
  );
  if (!Number.isFinite(limit) || limit <= 0 || !Number.isFinite(windowSeconds) || windowSeconds <= 0) {
    throw new Error(
      "Invalid Gemini rate limit. Set OPENCLAW_ADAPTER_GEMINI_RATE_LIMIT_PER_MINUTE and OPENCLAW_ADAPTER_GEMINI_RATE_WINDOW_SECONDS to positive integers.",
    );
  }
  if (typeof globalThis.fetch !== "function") {
    return;
  }

  const originalFetch = globalThis.fetch.bind(globalThis);
  const intervalMs = Math.ceil((windowSeconds * 1000) / limit);
  let nextAllowedAt = 0;
  let queue = Promise.resolve();

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const isGeminiModelRequest = (resource) => {
    const url =
      typeof resource === "string"
        ? resource
        : resource instanceof URL
          ? resource.href
          : typeof resource?.url === "string"
            ? resource.url
            : "";
    if (!url) {
      return false;
    }
    try {
      const parsed = new URL(url);
      return (
        parsed.hostname === "generativelanguage.googleapis.com" &&
        /:generateContent|:streamGenerateContent/.test(parsed.pathname)
      );
    } catch {
      return url.includes("generativelanguage.googleapis.com") && url.includes("generateContent");
    }
  };

  globalThis.fetch = async (...args) => {
    if (!isGeminiModelRequest(args[0])) {
      return originalFetch(...args);
    }

    const previous = queue;
    let release;
    queue = new Promise((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      const now = Date.now();
      const waitMs = Math.max(0, nextAllowedAt - now);
      if (waitMs > 0) {
        console.error(`[openclaw_run_once] Gemini API rate limit sleep ${Math.ceil(waitMs / 1000)}s`);
        await sleep(waitMs);
      }
      nextAllowedAt = Date.now() + intervalMs;
      return await originalFetch(...args);
    } finally {
      release();
    }
  };

  console.error(
    `[openclaw_run_once] Gemini API rate limit enabled: ${limit} calls per ${windowSeconds}s`,
  );
}

async function loadOpenClawApi(openclawRoot) {
  const distRoot = path.join(openclawRoot, "dist");
  console.error(`[openclaw_run_once] loading OpenClaw API from ${distRoot}`);
  if (!(await fileExists(distRoot))) {
    throw new Error(`OpenClaw dist directory not found: ${distRoot}`);
  }
  const distEntries = await fs.readdir(distRoot);
  const piEmbeddedBundles = await Promise.all(
    distEntries
      .filter((entry) => entry.startsWith("pi-embedded-") && entry.endsWith(".js"))
      .map(async (entry) => ({
        entry,
        mtimeMs: (await fs.stat(path.join(distRoot, entry))).mtimeMs,
      })),
  );
  const piEmbeddedBundle = piEmbeddedBundles.toSorted((a, b) => b.mtimeMs - a.mtimeMs)[0]?.entry;
  if (!piEmbeddedBundle) {
    throw new Error(`Could not find pi-embedded bundle under ${distRoot}`);
  }
  console.error(`[openclaw_run_once] selected ${piEmbeddedBundle}`);

  const [piEmbeddedModule, runtimeModule] = await Promise.all([
    import(path.join(distRoot, piEmbeddedBundle)),
    import(path.join(distRoot, "plugin-sdk", "runtime.js")),
  ]);
  console.error("[openclaw_run_once] OpenClaw modules imported");

  const exportedFunctions = Object.values(piEmbeddedModule).filter(
    (value) => typeof value === "function",
  );
  const agentCommand = exportedFunctions.find((fn) => fn.name === "agentCommand");
  const agentCommandFromIngress = exportedFunctions.find(
    (fn) => fn.name === "agentCommandFromIngress",
  );
  if (typeof agentCommand !== "function" || typeof agentCommandFromIngress !== "function") {
    throw new Error(`Could not resolve OpenClaw agent command helpers from ${piEmbeddedBundle}`);
  }

  return {
    agentCommand,
    agentCommandFromIngress,
    runtime: runtimeModule.createNonExitingRuntime(),
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const request = JSON.parse(await fs.readFile(args.input, "utf8"));

  process.env.OPENCLAW_STATE_DIR = request.stateDir;
  process.env.OPENCLAW_CONFIG_PATH = request.configPath;
  process.env.OPENCLAW_HOME = request.openclawHome || request.stateDir;
  process.env.HOME = request.homeDir || process.env.HOME || request.stateDir;
  installGeminiFetchRateLimiter();

  const startedAt = new Date().toISOString();
  const output = {
    schema_version: 1,
    status: "started",
    started_at: startedAt,
    request,
  };

  try {
    const api = await loadOpenClawApi(request.openclawRoot);
    const messages = Array.isArray(request.messages) && request.messages.length > 0 ? request.messages : [request.goal];
    const turnResults = [];
    let result = null;
    for (let index = 0; index < messages.length; index += 1) {
      console.error(`[openclaw_run_once] starting turn ${index + 1}/${messages.length}`);
      result = await api.agentCommandFromIngress(
        {
          agentId: request.agentId || "main",
          sessionKey: request.sessionKey || "agent:main:openclaw-adapter",
          message: String(messages[index] ?? ""),
          workspaceDir: request.workspaceDir,
          senderIsOwner: request.senderIsOwner !== false,
          allowModelOverride: false,
          messageChannel: request.messageChannel || "web",
          runContext: {
            adapter: "openclaw_adapter",
            caseId: request.caseId,
            runId: request.runId,
            mockGatewayBaseUrl: request.mockGatewayBaseUrl,
            turnIndex: index + 1,
            turnCount: messages.length,
          },
        },
        api.runtime,
      );
      console.error(`[openclaw_run_once] completed turn ${index + 1}/${messages.length}`);
      turnResults.push({
        turn: index + 1,
        message: String(messages[index] ?? ""),
        response_text: payloadText(result),
        raw_result: JSON.parse(safeStringify(result)),
      });
    }

    output.status = "completed";
    output.completed_at = new Date().toISOString();
    output.response_text = payloadText(result);
    output.turns = turnResults;
    output.raw_result = JSON.parse(safeStringify(result));
    await fs.writeFile(args.output, safeStringify(output), "utf8");
    process.exit(0);
  } catch (error) {
    output.status = "failed";
    output.completed_at = new Date().toISOString();
    output.error = JSON.parse(safeStringify(error));
    await fs.writeFile(args.output, safeStringify(output), "utf8");
    console.error(error?.stack || String(error));
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
