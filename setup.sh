#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-help}
PROFILE_ARG=${2:-k160}

SPARK_ROOT=${SPARK_ROOT:-${HOME}/spark}
TAILSCALE_HOST=${TAILSCALE_HOST:-0.0.0.0}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_ROOT=${INSTALL_ROOT:-${SPARK_ROOT}/deepseek-spark}

VLLM_STUDIO_REPO=${VLLM_STUDIO_REPO:-https://github.com/sybil-solutions/vllm-studio.git}
VLLM_STUDIO_REF=${VLLM_STUDIO_REF:-main}
VLLM_STUDIO_DIR=${VLLM_STUDIO_DIR:-${SPARK_ROOT}/services/vllm-studio}
BUN_BIN=${BUN_BIN:-$(command -v bun || echo "${HOME}/.bun/bin/bun")}
FRONTEND_NPM_INSTALL_FLAGS=${FRONTEND_NPM_INSTALL_FLAGS:---legacy-peer-deps}

MODEL_MODULE_DIR=${MODEL_MODULE_DIR:-${INSTALL_ROOT}/runtime}

CONTROLLER_HOST=${CONTROLLER_HOST:-$TAILSCALE_HOST}
CONTROLLER_PORT=${CONTROLLER_PORT:-8080}
INFERENCE_HOST=${INFERENCE_HOST:-$TAILSCALE_HOST}
INFERENCE_PORT=${INFERENCE_PORT:-8000}
FRONTEND_HOST=${FRONTEND_HOST:-$TAILSCALE_HOST}
FRONTEND_PORT=${FRONTEND_PORT:-3000}
DATA_DIR=${DATA_DIR:-${INSTALL_ROOT}/studio-data}
FRONTEND_DATA_DIR=${FRONTEND_DATA_DIR:-${DATA_DIR}/frontend}
PID_DIR=${PID_DIR:-${INSTALL_ROOT}/pids}
LOG_DIR=${LOG_DIR:-${INSTALL_ROOT}/logs}
ENV_FILE=${ENV_FILE:-${INSTALL_ROOT}/runtime/studio.env}

profile_name() {
  case "${1:-k160}" in
    k144|k144-nospec-200k) echo k144-nospec-200k ;;
    k160|k160-mtp2-200k) echo k160-mtp2-200k ;;
    *) echo "unknown profile: $1" >&2; exit 2 ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  ./setup.sh model [k160|k144]       install and launch only the model API
  ./setup.sh controller              start vLLM Studio controller and preload recipes
  ./setup.sh api [k160|k144]         start controller, preload recipes, launch recipe through controller
  ./setup.sh frontend                start only the optional frontend for the configured controller
  ./setup.sh full [k160|k144]        api mode plus optional frontend
  ./setup.sh pi-models               merge Spark models into ~/.pi/agent/models.json
  ./setup.sh status                  show service status
  ./setup.sh stop                    stop wrapper-launched services and model containers

Useful overrides:
  CONTROLLER_PORT=18080 INFERENCE_PORT=18000 ./setup.sh api k160
  VLLM_STUDIO_DIR=${HOME}/spark/services/vllm-studio ./setup.sh controller
  UPDATE_PI_MODELS=0 ./setup.sh full k160
EOF
}

ensure_dirs() {
  mkdir -p "$INSTALL_ROOT" "$DATA_DIR" "$FRONTEND_DATA_DIR" "$PID_DIR" "$LOG_DIR" "$(dirname "$ENV_FILE")"
}

sync_self() {
  ensure_dirs
  if [[ "$REPO_ROOT" != "$INSTALL_ROOT" ]]; then
    rsync -a --delete \
      --exclude .git \
      --exclude runtime/studio.env \
      --exclude studio-data \
      --exclude pids \
      --exclude logs \
      "$REPO_ROOT"/ "$INSTALL_ROOT"/
  fi
}

ensure_model_module() {
  if [[ ! -x "${MODEL_MODULE_DIR}/install.sh" ]]; then
    echo "missing runtime at ${MODEL_MODULE_DIR}" >&2
    exit 1
  fi
}

ensure_studio() {
  if [[ ! -f "${VLLM_STUDIO_DIR}/controller/src/main.ts" ]]; then
    rm -rf "$VLLM_STUDIO_DIR"
    git clone "$VLLM_STUDIO_REPO" "$VLLM_STUDIO_DIR"
  fi
  (
    cd "$VLLM_STUDIO_DIR"
    git remote set-url origin "$VLLM_STUDIO_REPO"
    git fetch origin "$VLLM_STUDIO_REF" --tags --prune
    git checkout -B "$VLLM_STUDIO_REF" "origin/$VLLM_STUDIO_REF"
    git reset --hard "origin/$VLLM_STUDIO_REF"
  )
  if [[ ! -x "$BUN_BIN" ]]; then
    echo "missing Bun at $BUN_BIN" >&2
    echo "install Bun or set BUN_BIN=/path/to/bun" >&2
    exit 1
  fi
  if [[ ! -d "${VLLM_STUDIO_DIR}/controller/node_modules" ]]; then
    (cd "${VLLM_STUDIO_DIR}/controller" && "$BUN_BIN" install)
  fi
}

random_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))'
  fi
}

write_env() {
  ensure_dirs
  local key
  if [[ -f "$ENV_FILE" ]]; then
    key=$(grep '^VLLM_STUDIO_API_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
  fi
  key=${VLLM_STUDIO_API_KEY:-${key:-$(random_key)}}
  cat > "$ENV_FILE" <<EOF
VLLM_STUDIO_HOST=${CONTROLLER_HOST}
VLLM_STUDIO_PORT=${CONTROLLER_PORT}
VLLM_STUDIO_API_KEY=${key}
VLLM_STUDIO_CORS_ORIGINS=http://${FRONTEND_HOST}:${FRONTEND_PORT},http://localhost:${FRONTEND_PORT},http://127.0.0.1:${FRONTEND_PORT}
VLLM_STUDIO_INFERENCE_HOST=${INFERENCE_HOST}
VLLM_STUDIO_INFERENCE_PORT=${INFERENCE_PORT}
VLLM_STUDIO_MODELS_DIR=${SPARK_ROOT}/models/hf-cache
VLLM_STUDIO_DATA_DIR=${DATA_DIR}
VLLM_STUDIO_DB_PATH=${DATA_DIR}/controller.db
VLLM_STUDIO_STRICT_OPENAI_MODELS=false
VLLM_STUDIO_DISABLE_METRICS=0
VLLM_STUDIO_LOG_RETENTION_DAYS=30
VLLM_STUDIO_LOG_MAX_FILES=200
EOF
  chmod 600 "$ENV_FILE"
}

load_env() {
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  export VLLM_STUDIO_HOST VLLM_STUDIO_PORT VLLM_STUDIO_API_KEY VLLM_STUDIO_CORS_ORIGINS
  export VLLM_STUDIO_INFERENCE_HOST VLLM_STUDIO_INFERENCE_PORT VLLM_STUDIO_MODELS_DIR
  export VLLM_STUDIO_DATA_DIR VLLM_STUDIO_DB_PATH VLLM_STUDIO_STRICT_OPENAI_MODELS
  export VLLM_STUDIO_DISABLE_METRICS VLLM_STUDIO_LOG_RETENTION_DAYS VLLM_STUDIO_LOG_MAX_FILES
}

load_or_write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    load_env
  else
    write_env
    load_env
  fi
  CONTROLLER_HOST=${VLLM_STUDIO_HOST}
  CONTROLLER_PORT=${VLLM_STUDIO_PORT}
  INFERENCE_HOST=${VLLM_STUDIO_INFERENCE_HOST}
  INFERENCE_PORT=${VLLM_STUDIO_INFERENCE_PORT}
}

pid_alive() {
  local file=$1
  [[ -f "$file" ]] && kill -0 "$(cat "$file")" >/dev/null 2>&1
}

listener_pid_for_port() {
  local port=$1
  ss -ltnp 2>/dev/null |
    sed -n "s/.*:${port}[[:space:]].*pid=\\([0-9][0-9]*\\).*/\\1/p" |
    head -1
}

controller_status_ok() {
  curl -fsS -H "x-api-key: ${VLLM_STUDIO_API_KEY}" \
    "http://${CONTROLLER_HOST}:${CONTROLLER_PORT}/status" >/dev/null 2>&1
}

update_pi_models() {
  load_env
  CONTROLLER_HOST=${VLLM_STUDIO_HOST}
  CONTROLLER_PORT=${VLLM_STUDIO_PORT}
  local update_mode=${UPDATE_PI_MODELS:-auto}
  local pi_root=${PI_ROOT:-$HOME/.pi}
  case "$update_mode" in
    0|false|FALSE|no|NO|off|OFF)
      echo "Pi models update skipped (UPDATE_PI_MODELS=${update_mode})"
      return 0
      ;;
    auto)
      if [[ ! -d "$pi_root" ]]; then
        echo "Pi models update skipped (no ${pi_root}; set UPDATE_PI_MODELS=1 to create it)"
        return 0
      fi
      ;;
    1|true|TRUE|yes|YES|on|ON|force|always)
      ;;
    *)
      echo "unknown UPDATE_PI_MODELS=${update_mode}" >&2
      return 2
      ;;
  esac
  CONTROLLER_HOST="$CONTROLLER_HOST" \
  CONTROLLER_PORT="$CONTROLLER_PORT" \
  VLLM_STUDIO_API_KEY="$VLLM_STUDIO_API_KEY" \
  PI_ROOT="$pi_root" \
  node "${INSTALL_ROOT}/scripts/update_pi_models.mjs"
}

start_controller() {
  ensure_studio
  write_env
  load_env
  if controller_status_ok; then
    local pid
    pid=$(listener_pid_for_port "$CONTROLLER_PORT" || true)
    if [[ -n "$pid" ]]; then
      echo "$pid" > "${PID_DIR}/controller.pid"
      echo "controller already running pid=${pid}"
    else
      echo "controller already running"
    fi
  elif pid_alive "${PID_DIR}/controller.pid"; then
    echo "controller process exists but did not answer status; restarting"
    kill "$(cat "${PID_DIR}/controller.pid")" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$(cat "${PID_DIR}/controller.pid")" >/dev/null 2>&1 || true
    rm -f "${PID_DIR}/controller.pid"
    nohup "$BUN_BIN" "${VLLM_STUDIO_DIR}/controller/src/main.ts" \
      > "${LOG_DIR}/controller.log" 2>&1 &
    echo $! > "${PID_DIR}/controller.pid"
  else
    local existing_pid
    existing_pid=$(listener_pid_for_port "$CONTROLLER_PORT" || true)
    if [[ -n "$existing_pid" ]]; then
      echo "port ${CONTROLLER_PORT} is already in use by pid ${existing_pid}; set TAKEOVER_PORT=1 to replace it" >&2
      if [[ "${TAKEOVER_PORT:-0}" != "1" ]]; then
        exit 1
      fi
      kill "$existing_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$existing_pid" >/dev/null 2>&1 || true
    fi
    nohup "$BUN_BIN" "${VLLM_STUDIO_DIR}/controller/src/main.ts" \
      > "${LOG_DIR}/controller.log" 2>&1 &
    echo $! > "${PID_DIR}/controller.pid"
  fi
  wait_controller_url "http://${CONTROLLER_HOST}:${CONTROLLER_PORT}/status" 60
  CONTROLLER_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
  API_KEY="$VLLM_STUDIO_API_KEY" \
  SPARK_ROOT="$SPARK_ROOT" \
  MODEL_MODULE_DIR="$MODEL_MODULE_DIR" \
  INFERENCE_HOST="$INFERENCE_HOST" \
  INFERENCE_PORT="$INFERENCE_PORT" \
  "${INSTALL_ROOT}/scripts/preload_recipes.sh"
  update_pi_models
  echo "controller ready: http://${CONTROLLER_HOST}:${CONTROLLER_PORT}"
}

prepare_frontend_settings() {
  load_env
  mkdir -p "$FRONTEND_DATA_DIR"
  chmod 700 "$FRONTEND_DATA_DIR" >/dev/null 2>&1 || true
  umask 077
  cat > "${FRONTEND_DATA_DIR}/api-settings.json" <<EOF
{
  "backendUrl": "http://${CONTROLLER_HOST}:${CONTROLLER_PORT}",
  "apiKey": "${VLLM_STUDIO_API_KEY}",
  "voiceUrl": "",
  "voiceModel": "whisper-large-v3-turbo"
}
EOF
}

start_frontend() {
  ensure_studio
  write_env
  load_env
  prepare_frontend_settings
  if [[ ! -d "${VLLM_STUDIO_DIR}/frontend/node_modules" ]]; then
    (cd "${VLLM_STUDIO_DIR}/frontend" && npm install $FRONTEND_NPM_INSTALL_FLAGS)
  fi
  if [[ "${FORCE_FRONTEND_BUILD:-0}" == "1" || ! -d "${VLLM_STUDIO_DIR}/frontend/.next" ]]; then
    (cd "${VLLM_STUDIO_DIR}/frontend" && \
      VLLM_STUDIO_DATA_DIR="$FRONTEND_DATA_DIR" \
      NEXT_PUBLIC_API_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
      NEXT_PUBLIC_BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
      VLLM_STUDIO_BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
      BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
      API_KEY="${VLLM_STUDIO_API_KEY}" \
      npm run build)
  fi
  local existing_pid
  existing_pid=$(listener_pid_for_port "$FRONTEND_PORT" || true)
  if [[ -n "$existing_pid" && frontend_proxy_ok ]]; then
    echo "$existing_pid" > "${PID_DIR}/frontend.pid"
    echo "frontend already running pid=${existing_pid}"
  elif pid_alive "${PID_DIR}/frontend.pid" && frontend_proxy_ok; then
    echo "frontend already running pid=$(cat "${PID_DIR}/frontend.pid")"
  else
    if pid_alive "${PID_DIR}/frontend.pid"; then
      local pid
      pid=$(cat "${PID_DIR}/frontend.pid")
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
      rm -f "${PID_DIR}/frontend.pid"
    fi
    existing_pid=$(listener_pid_for_port "$FRONTEND_PORT" || true)
    if [[ -n "$existing_pid" ]]; then
      echo "frontend port ${FRONTEND_PORT} is already in use by pid ${existing_pid}; set TAKEOVER_PORT=1 to replace it" >&2
      if [[ "${TAKEOVER_PORT:-0}" != "1" ]]; then
        exit 1
      fi
      kill "$existing_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$existing_pid" >/dev/null 2>&1 || true
    fi
    (cd "${VLLM_STUDIO_DIR}/frontend" && \
      setsid -f env \
        VLLM_STUDIO_DATA_DIR="$FRONTEND_DATA_DIR" \
        NEXT_PUBLIC_API_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
        NEXT_PUBLIC_BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
        VLLM_STUDIO_BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
        BACKEND_URL="http://${CONTROLLER_HOST}:${CONTROLLER_PORT}" \
        API_KEY="${VLLM_STUDIO_API_KEY}" \
        npm run start:next -- -H "$FRONTEND_HOST" -p "$FRONTEND_PORT" \
      > "${LOG_DIR}/frontend.log" 2>&1 < /dev/null)
    sleep 1
    local frontend_pid
    frontend_pid=$(listener_pid_for_port "$FRONTEND_PORT" || true)
    if [[ -n "$frontend_pid" ]]; then
      echo "$frontend_pid" > "${PID_DIR}/frontend.pid"
    fi
  fi
  wait_url "http://${FRONTEND_HOST}:${FRONTEND_PORT}" 90
  echo "frontend ready: http://${FRONTEND_HOST}:${FRONTEND_PORT}"
}

wait_url() {
  local url=$1
  local timeout=${2:-60}
  local deadline=$((SECONDS + timeout))
  until curl -fsS "$url" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for $url" >&2
      return 1
    fi
    sleep 1
  done
}

wait_controller_url() {
  local url=$1
  local timeout=${2:-60}
  local deadline=$((SECONDS + timeout))
  until curl -fsS -H "x-api-key: ${VLLM_STUDIO_API_KEY}" "$url" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for $url" >&2
      return 1
    fi
    sleep 1
  done
}

frontend_proxy_ok() {
  curl -fsS "http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/proxy/status" >/dev/null 2>&1
}

start_model_direct() {
  local profile
  profile=$(profile_name "$1")
  ensure_model_module
  "$MODEL_MODULE_DIR/install.sh" --profile "$profile" --no-launch
  PROFILE="$profile" \
  SPARK_ROOT="$SPARK_ROOT" \
  MODEL_MODULE_DIR="$MODEL_MODULE_DIR" \
  HOST="$INFERENCE_HOST" \
  PORT="$INFERENCE_PORT" \
  "${INSTALL_ROOT}/scripts/studio_model_entrypoint.sh" --profile "$profile" --host "$INFERENCE_HOST" --port "$INFERENCE_PORT" --detach
  echo "model API ready: http://${INFERENCE_HOST}:${INFERENCE_PORT}"
}

launch_via_controller() {
  local profile recipe_id
  profile=$(profile_name "$1")
  if [[ "$profile" == "k144-nospec-200k" ]]; then
    recipe_id=deepseek-v4-flash-spark-mini
  else
    recipe_id=deepseek-v4-flash-spark
  fi
  load_env
  local launch_rc=0
  curl -fsS --max-time "${LAUNCH_REQUEST_TIMEOUT_SECONDS:-15}" \
    -X POST \
    -H "x-api-key: ${VLLM_STUDIO_API_KEY}" \
    "http://${CONTROLLER_HOST}:${CONTROLLER_PORT}/launch/${recipe_id}" >/dev/null || launch_rc=$?
  if [[ "$launch_rc" != "0" && "$launch_rc" != "28" && "$launch_rc" != "52" ]]; then
    echo "launch request failed with curl exit ${launch_rc}" >&2
    return "$launch_rc"
  fi
  wait_url "http://${INFERENCE_HOST}:${INFERENCE_PORT}/health" "${MODEL_READY_TIMEOUT_SECONDS:-520}"
  echo "controller-launched model ready: ${recipe_id}"
}

status() {
  if [[ -f "$ENV_FILE" ]]; then
    load_env
    CONTROLLER_HOST=${VLLM_STUDIO_HOST}
    CONTROLLER_PORT=${VLLM_STUDIO_PORT}
    INFERENCE_HOST=${VLLM_STUDIO_INFERENCE_HOST}
    INFERENCE_PORT=${VLLM_STUDIO_INFERENCE_PORT}
  fi
  echo "repo: ${INSTALL_ROOT}"
  [[ -f "$ENV_FILE" ]] && echo "env: ${ENV_FILE}"
  if controller_status_ok; then
    local pid
    pid=$(listener_pid_for_port "$CONTROLLER_PORT" || true)
    echo "controller: running${pid:+ pid=${pid}}"
  else
    echo "controller: stopped"
  fi
  for name in frontend; do
    if pid_alive "${PID_DIR}/${name}.pid"; then
      echo "${name}: running pid=$(cat "${PID_DIR}/${name}.pid")"
    else
      echo "${name}: stopped"
    fi
  done
  docker ps --format '{{.Names}} {{.Image}} {{.Ports}}' | grep -E 'studio-deepseek-v4-flash-spark' || true
}

stop_all() {
  if [[ -f "$ENV_FILE" ]]; then
    load_env
    CONTROLLER_HOST=${VLLM_STUDIO_HOST}
    CONTROLLER_PORT=${VLLM_STUDIO_PORT}
    INFERENCE_HOST=${VLLM_STUDIO_INFERENCE_HOST}
    INFERENCE_PORT=${VLLM_STUDIO_INFERENCE_PORT}
  fi
  for name in frontend controller; do
    if pid_alive "${PID_DIR}/${name}.pid"; then
      local pid
      pid=$(cat "${PID_DIR}/${name}.pid")
      kill "$pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        sleep 0.25
      done
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -9 "$pid" >/dev/null 2>&1 || true
      fi
      rm -f "${PID_DIR}/${name}.pid"
    fi
  done
  local controller_listener
  controller_listener=$(listener_pid_for_port "$CONTROLLER_PORT" || true)
  if [[ -n "$controller_listener" && "${STOP_LISTENER:-0}" == "1" ]]; then
    kill "$controller_listener" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$controller_listener" >/dev/null 2>&1 || true
  fi
  local frontend_listener
  frontend_listener=$(listener_pid_for_port "$FRONTEND_PORT" || true)
  if [[ -n "$frontend_listener" && "${STOP_LISTENER:-0}" == "1" ]]; then
    kill "$frontend_listener" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$frontend_listener" >/dev/null 2>&1 || true
  fi
  docker ps -a --format '{{.Names}}' |
    grep -E '^studio-deepseek-v4-flash-spark' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
}

main() {
  case "$MODE" in
    model)
      sync_self
      start_model_direct "$PROFILE_ARG"
      ;;
    controller)
      sync_self
      start_controller
      ;;
    api|all)
      sync_self
      start_controller
      launch_via_controller "$PROFILE_ARG"
      ;;
    frontend)
      sync_self
      write_env
      start_frontend
      ;;
    pi-models)
      sync_self
      load_or_write_env
      update_pi_models
      ;;
    full)
      sync_self
      start_controller
      launch_via_controller "$PROFILE_ARG"
      start_frontend
      ;;
    status)
      status
      ;;
    stop)
      stop_all
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
