#!/usr/bin/env bash
set -euo pipefail

PROFILE=${PROFILE:-k160-mtp2-200k}
SPARK_ROOT=${SPARK_ROOT:-$HOME/spark}
MODEL_MODULE_DIR=${MODEL_MODULE_DIR:-${SPARK_ROOT}/deepseek-spark/runtime}
HOST=${HOST:-<spark-tailnet-ip>}
PORT=${PORT:-8000}
DEEPSEEK_THINKING=${DEEPSEEK_THINKING:-true}
DETACH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE=${2:?missing profile}
      shift 2
      ;;
    --host)
      HOST=${2:?missing host}
      shift 2
      ;;
    --port)
      PORT=${2:?missing port}
      shift 2
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$PROFILE" in
  k144|k144-nospec-200k)
    PROFILE=k144-nospec-200k
    DEFAULT_SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark-Mini
    DEFAULT_CONTAINER_NAME=studio-deepseek-v4-flash-spark-mini-${PORT}
    ;;
  k160|k160-mtp2-200k)
    PROFILE=k160-mtp2-200k
    DEFAULT_SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
    DEFAULT_CONTAINER_NAME=studio-deepseek-v4-flash-spark-${PORT}
    ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 2 ;;
esac

if [[ ! -x "${MODEL_MODULE_DIR}/install.sh" ]]; then
  echo "missing model module at ${MODEL_MODULE_DIR}; run setup.sh first" >&2
  exit 1
fi

"${MODEL_MODULE_DIR}/install.sh" --profile "$PROFILE" --no-launch

NAME=${NAME:-$DEFAULT_CONTAINER_NAME}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-$DEFAULT_SERVED_MODEL_NAME}
PROFILE="$PROFILE" \
HOST="$HOST" \
PORT="$PORT" \
NAME="$NAME" \
SERVED_MODEL_NAME_OVERRIDE="$SERVED_MODEL_NAME" \
THINKING_OVERRIDE="$DEEPSEEK_THINKING" \
"${MODEL_MODULE_DIR}/scripts/serve_profile.sh"

deadline=$((SECONDS + ${READY_TIMEOUT_SECONDS:-420}))
until curl -fsS "http://${HOST}:${PORT}/health" >/dev/null 2>&1; do
  if ! docker inspect "$NAME" >/dev/null 2>&1; then
    echo "container disappeared before readiness: ${NAME}" >&2
    exit 1
  fi
  running=$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)
  if [[ "$running" != "true" ]]; then
    echo "container stopped before readiness: ${NAME}" >&2
    docker logs --tail 120 "$NAME" >&2 || true
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "timed out waiting for http://${HOST}:${PORT}/health" >&2
    docker logs --tail 120 "$NAME" >&2 || true
    exit 1
  fi
  sleep 2
done

echo "model ready: http://${HOST}:${PORT}"
echo "container: ${NAME}"

if [[ "$DETACH" == "1" ]]; then
  exit 0
fi

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup INT TERM

docker logs -f "$NAME" &
wait $!
