#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTROLLER_URL=${CONTROLLER_URL:-http://100.83.190.2:8080}
API_KEY=${VLLM_STUDIO_API_KEY:-${API_KEY:-}}
INFERENCE_HOST=${INFERENCE_HOST:-100.83.190.2}
INFERENCE_PORT=${INFERENCE_PORT:-8000}
SPARK_ROOT=${SPARK_ROOT:-$HOME/spark}
MODEL_MODULE_DIR=${MODEL_MODULE_DIR:-${SPARK_ROOT}/deepseek-spark/runtime}

if [[ -z "$API_KEY" ]]; then
  echo "set API_KEY or VLLM_STUDIO_API_KEY" >&2
  exit 2
fi

patch_recipe() {
  local input=$1
  node - "$input" "$SPARK_ROOT" "$INFERENCE_HOST" "$INFERENCE_PORT" <<'NODE'
const fs = require("node:fs");
const [path, sparkRoot, host, portRaw] = process.argv.slice(2);
const port = Number(portRaw);
const recipe = JSON.parse(fs.readFileSync(path, "utf8"));
recipe.host = host;
recipe.port = port;
recipe.model_path = recipe.model_path.replace("/home/sero/spark", sparkRoot);
recipe.env_vars = recipe.env_vars || {};
recipe.env_vars.MODEL_MODULE_DIR = process.env.MODEL_MODULE_DIR;
recipe.extra_args.launch_command = recipe.extra_args.launch_command
  .replace("/home/sero/spark", sparkRoot)
  .replace("--host 100.83.190.2", `--host ${host}`)
  .replace("--port 8000", `--port ${port}`);
const containerBase = recipe.env_vars.PROFILE === "k144-nospec-200k"
  ? "studio-deepseek-v4-flash-spark-mini"
  : "studio-deepseek-v4-flash-spark";
recipe.extra_args.docker_container = `${containerBase}-${port}`;
process.stdout.write(JSON.stringify(recipe));
NODE
}

for recipe in "$REPO_ROOT"/config/recipes/*.json; do
  payload=$(patch_recipe "$recipe")
  id=$(node -e 'const x=JSON.parse(process.argv[1]); process.stdout.write(x.id)' "$payload")
  curl -fsS \
    -X PUT \
    -H "content-type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    --data "$payload" \
    "${CONTROLLER_URL}/recipes/${id}" >/dev/null
  echo "preloaded ${id}"
done
