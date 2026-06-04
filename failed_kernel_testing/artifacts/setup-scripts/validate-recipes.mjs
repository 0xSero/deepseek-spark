import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const required = [
  "id",
  "name",
  "backend",
  "model_path",
  "served_model_name",
  "max_model_len",
  "extra_args",
];

const expected = {
  k144: {
    id: "deepseek-v4-flash-spark-mini",
    servedModelName: "DeepSeek-V4-Flash-Spark-Mini",
    profile: "k144-nospec-200k",
    containerPrefix: "studio-deepseek-v4-flash-spark-mini-",
  },
  k160: {
    id: "deepseek-v4-flash-spark",
    servedModelName: "DeepSeek-V4-Flash-Spark",
    profile: "k160-mtp2-200k",
    containerPrefix: "studio-deepseek-v4-flash-spark-",
  },
};

for (const name of ["k144", "k160"]) {
  const path = join(root, "recipes", `${name}.json`);
  const recipe = JSON.parse(readFileSync(path, "utf8"));
  const target = expected[name];
  for (const key of required) {
    if (!(key in recipe)) throw new Error(`${path} missing ${key}`);
  }
  if (recipe.id !== target.id) throw new Error(`${path} id must be ${target.id}`);
  if (recipe.served_model_name !== target.servedModelName) {
    throw new Error(`${path} served model must be ${target.servedModelName}`);
  }
  if (recipe.env_vars?.PROFILE !== target.profile) throw new Error(`${path} profile must be ${target.profile}`);
  if (recipe.backend !== "vllm") throw new Error(`${path} must use vllm backend`);
  if (recipe.max_model_len !== 200000) throw new Error(`${path} must target 200K context`);
  if (recipe.tool_call_parser !== "deepseek_v4") throw new Error(`${path} must use tool parser deepseek_v4`);
  if (recipe.reasoning_parser !== "deepseek_v4") throw new Error(`${path} must use reasoning parser deepseek_v4`);
  if (recipe.env_vars?.DEEPSEEK_THINKING !== "true") throw new Error(`${path} must enable DeepSeek thinking`);
  const moduleDir = String(recipe.env_vars?.MODEL_MODULE_DIR ?? "");
  if (!moduleDir.includes("/deepseek-spark/runtime") && !moduleDir.includes("<repo-root>/runtime")) {
    throw new Error(`${path} must point at the wrapper-owned model module`);
  }
  if (!String(recipe.extra_args.docker_container ?? "").startsWith(target.containerPrefix)) {
    throw new Error(`${path} must expose the predictable Docker container name for logs`);
  }
  if (!String(recipe.extra_args.launch_command ?? "").includes("studio_model_entrypoint.sh")) {
    throw new Error(`${path} missing Studio blocking entrypoint`);
  }
  const launchCommand = String(recipe.extra_args.launch_command ?? "");
  if (!launchCommand.includes("/deepseek-spark/") && !launchCommand.includes("<repo-root>/")) {
    throw new Error(`${path} must point at the deepseek-spark repository`);
  }
}

console.log("recipes ok");
