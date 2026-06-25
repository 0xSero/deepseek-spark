#!/usr/bin/env node
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const providerId = process.env.PI_MODELS_PROVIDER_ID || "deepseek-spark";
const piRoot = process.env.PI_ROOT || join(homedir(), ".pi");
const agentDir = process.env.PI_AGENT_DIR || join(piRoot, "agent");
const modelsPath = process.env.PI_MODELS_PATH || join(agentDir, "models.json");
const controllerHost = process.env.CONTROLLER_HOST || process.env.VLLM_STUDIO_HOST || "0.0.0.0";
const controllerPort = process.env.CONTROLLER_PORT || process.env.VLLM_STUDIO_PORT || "8080";
const baseUrl = stripTrailingSlash(
  process.env.PI_MODELS_BASE_URL || `http://${controllerHost}:${controllerPort}/v1`,
);
const apiKey = process.env.PI_MODELS_API_KEY || process.env.VLLM_STUDIO_API_KEY || process.env.API_KEY || "";
const maxTokens = parsePositiveInt(process.env.PI_MODEL_MAX_TOKENS, 8192);

function stripTrailingSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "Z");
}

function makeModel(id, name) {
  return {
    id,
    name,
    reasoning: true,
    input: ["text"],
    contextWindow: 200000,
    maxTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    thinkingLevelMap: {
      off: null,
      minimal: null,
      low: "low",
      medium: "medium",
      high: "high",
      xhigh: "max",
    },
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: true,
      maxTokensField: "max_tokens",
      thinkingFormat: "deepseek",
      requiresReasoningContentOnAssistantMessages: true,
    },
  };
}

function loadExistingConfig() {
  if (!existsSync(modelsPath)) return { config: { providers: {} }, text: null, invalidBackup: null };

  const text = readFileSync(modelsPath, "utf8");
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("models.json root must be an object");
    }
    if (!parsed.providers || typeof parsed.providers !== "object" || Array.isArray(parsed.providers)) {
      parsed.providers = {};
    }
    return { config: parsed, text, invalidBackup: null };
  } catch (error) {
    const invalidBackup = `${modelsPath}.invalid-deepseek-spark-${timestamp()}`;
    copyFileSync(modelsPath, invalidBackup);
    return { config: { providers: {} }, text, invalidBackup };
  }
}

mkdirSync(dirname(modelsPath), { recursive: true, mode: 0o700 });
mkdirSync(agentDir, { recursive: true, mode: 0o700 });
chmodSync(agentDir, 0o700);

const { config, text: existingText, invalidBackup } = loadExistingConfig();
config.providers[providerId] = {
  baseUrl,
  api: "openai-completions",
  apiKey: apiKey || "vllm-studio",
  authHeader: Boolean(apiKey),
  compat: {
    supportsDeveloperRole: false,
    supportsReasoningEffort: false,
  },
  models: [
    makeModel("DeepSeek-V4-Flash-Spark", "DeepSeek-V4-Flash-Spark"),
    makeModel("DeepSeek-V4-Flash-Spark-Mini", "DeepSeek-V4-Flash-Spark-Mini"),
  ],
};

const nextText = `${JSON.stringify(config, null, 2)}\n`;
if (existingText === nextText) {
  chmodSync(modelsPath, 0o600);
  console.log(`Pi models already current: ${modelsPath}`);
  process.exit(0);
}

let backupPath = invalidBackup;
if (existsSync(modelsPath) && !backupPath) {
  backupPath = `${modelsPath}.bak-deepseek-spark-${timestamp()}`;
  copyFileSync(modelsPath, backupPath);
}

const tmpPath = `${modelsPath}.tmp-deepseek-spark-${process.pid}`;
writeFileSync(tmpPath, nextText, { encoding: "utf8", mode: 0o600 });
renameSync(tmpPath, modelsPath);
chmodSync(modelsPath, 0o600);

console.log(`Updated Pi models provider '${providerId}' in ${modelsPath}`);
console.log("Models: DeepSeek-V4-Flash-Spark, DeepSeek-V4-Flash-Spark-Mini");
if (backupPath) console.log(`Backup: ${backupPath}`);
