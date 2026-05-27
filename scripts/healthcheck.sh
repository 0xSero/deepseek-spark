#!/usr/bin/env bash
set -euo pipefail

CONTROLLER_URL=${CONTROLLER_URL:-http://100.83.190.2:8080}
API_KEY=${VLLM_STUDIO_API_KEY:-${API_KEY:-}}
INFERENCE_URL=${INFERENCE_URL:-http://100.83.190.2:8000}
EXPECTED_MODEL=${EXPECTED_MODEL:-}

auth_args=()
if [[ -n "$API_KEY" ]]; then
  auth_args=(-H "x-api-key: ${API_KEY}")
fi

json_get() {
  curl -fsS "${auth_args[@]}" "$1"
}

echo "controller status"
json_get "${CONTROLLER_URL}/status" >/dev/null

echo "controller recipes"
recipes_json=$(json_get "${CONTROLLER_URL}/recipes")
printf '%s' "$recipes_json" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); console.log(r.map(x=>`${x.id}:${x.status}`).join("\n")); if(!r.length) process.exit(1);})'
running_recipe=$(printf '%s' "$recipes_json" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); const one=r.find(x=>x.status==="running"); if(one) process.stdout.write(one.id);})')

echo "inference health"
curl -fsS "${INFERENCE_URL}/health" >/dev/null

echo "inference model"
model_name=$(curl -fsS "${INFERENCE_URL}/v1/models" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); const id=r.data?.[0]?.id; if(!id) process.exit(1); process.stdout.write(id);})')
echo "$model_name"
if [[ -n "$EXPECTED_MODEL" && "$model_name" != "$EXPECTED_MODEL" ]]; then
  echo "expected model ${EXPECTED_MODEL}, got ${model_name}" >&2
  exit 1
fi

echo "controller model catalog"
json_get "${CONTROLLER_URL}/v1/models" |
  MODEL_NAME="$model_name" node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); const ids=(r.data||[]).map(x=>x.id); console.log(ids.join("\n")); if(!ids.includes(process.env.MODEL_NAME)) process.exit(1);})'

echo "docker launch flags"
if [[ -n "$running_recipe" ]]; then
  container=$(printf '%s' "$recipes_json" |
    RUNNING_RECIPE="$running_recipe" node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); const one=r.find(x=>x.id===process.env.RUNNING_RECIPE); process.stdout.write(String(one?.extra_args?.docker_container||""));})')
  if [[ -n "$container" ]]; then
    cmd_json=$(docker inspect "$container" --format '{{json .Config.Cmd}}')
    printf '%s' "$cmd_json" |
      MODEL_NAME="$model_name" node -e '
        let s="";
        process.stdin.on("data",d=>s+=d);
        process.stdin.on("end",()=>{
          const text=JSON.parse(s).join(" ");
          const normalized=text.replace(/\\/g, "");
          const required=[
            "--trust-remote-code",
            "--tool-call-parser deepseek_v4",
            "--enable-auto-tool-choice",
            "--reasoning-parser deepseek_v4",
            "--reasoning-config",
            "--default-chat-template-kwargs",
            "\"thinking\":true",
            `--served-model-name ${process.env.MODEL_NAME}`,
          ];
          for (const needle of required) {
            if (!normalized.includes(needle)) {
              console.error(`missing launch flag: ${needle}`);
              process.exit(1);
            }
          }
          console.log("flags ok");
        })'
  fi
fi

echo "controller logs"
json_get "${CONTROLLER_URL}/logs" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); console.log(`${(r.sessions||[]).length} sessions`);})'
if [[ -n "$running_recipe" ]]; then
  json_get "${CONTROLLER_URL}/logs/${running_recipe}?limit=40" |
    node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); const n=(r.logs||[]).length; console.log(`${n} log lines`); if(n===0) process.exit(1);})'
fi

echo "controller metrics"
json_get "${CONTROLLER_URL}/v1/metrics/vllm" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{JSON.parse(s); console.log("metrics json ok");})'
json_get "${CONTROLLER_URL}/metrics" | grep -Eq 'vllm_studio_|process_|nodejs_|# HELP'

stream_check() {
  local url=$1
  local label=$2
  local payload
  payload=$(MODEL_NAME="$model_name" node -e 'process.stdout.write(JSON.stringify({model:process.env.MODEL_NAME,messages:[{role:"user",content:"Reply with exactly: stream ok"}],temperature:0,max_tokens:16,stream:true}))')
  local out
  out=$(curl -fsS -N --max-time "${STREAM_TIMEOUT_SECONDS:-180}" \
    "${auth_args[@]}" \
    -H "content-type: application/json" \
    --data "$payload" \
    "${url}/v1/chat/completions")
  printf '%s' "$out" | grep -q '^data:'
  printf '%s' "$out" | grep -q '\[DONE\]'
  echo "${label} streaming ok"
}

stream_check "$INFERENCE_URL" "direct"
stream_check "$CONTROLLER_URL" "controller"

echo "benchmark write path"
curl -fsS --max-time "${BENCHMARK_TIMEOUT_SECONDS:-180}" \
  "${auth_args[@]}" \
  -X POST \
  "${CONTROLLER_URL}/benchmark?prompt_tokens=32&max_tokens=8" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const r=JSON.parse(s); if(!r.success) { console.error(JSON.stringify(r)); process.exit(1); } console.log(`benchmark ok: ${r.model_id}`);})'
