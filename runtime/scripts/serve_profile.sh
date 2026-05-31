#!/usr/bin/env bash
set -euo pipefail

PROFILE=${PROFILE:-k160-mtp2-200k}
SPARK_ROOT=${SPARK_ROOT:-$HOME/spark}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG="${REPO_ROOT}/configs/${PROFILE}.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "missing profile config: $CONFIG" >&2
  exit 2
fi

set -a
# shellcheck source=/dev/null
source "$CONFIG"
set +a

hf_cache_root=${HF_HOME:-${SPARK_ROOT}/models/hf-cache}
primary_model_dir="${hf_cache_root}/models--${MODEL_REPO//\//--}/snapshots/${MODEL_REVISION}"
legacy_model_dir=""
if [[ -n "${MODEL_REPO_LEGACY:-}" ]]; then
  legacy_model_dir="${hf_cache_root}/models--${MODEL_REPO_LEGACY//\//--}/snapshots/${MODEL_REVISION}"
fi
if [[ -z "${MODEL_DIR:-}" ]]; then
  if [[ -d "$primary_model_dir" ]]; then
    MODEL_DIR="$primary_model_dir"
  elif [[ -n "$legacy_model_dir" && -d "$legacy_model_dir" ]]; then
    MODEL_DIR="$legacy_model_dir"
  else
    MODEL_DIR="$primary_model_dir"
  fi
fi
IMAGE=${IMAGE:-vllm-node-dsv4-cutlass451:latest}
PORT=${PORT:-8002}
HOST=${HOST:-100.83.190.2}

case "$PROFILE" in
  k144|k144-nospec-200k)
    DEFAULT_SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark-Mini
    DEFAULT_CONTAINER_NAME=studio-deepseek-v4-flash-spark-mini-${PORT}
    ;;
  k160|k160-mtp2-200k|k160-nospec-200k)
    DEFAULT_SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
    DEFAULT_CONTAINER_NAME=studio-deepseek-v4-flash-spark-${PORT}
    ;;
  *)
    DEFAULT_SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
    DEFAULT_CONTAINER_NAME=studio-deepseek-v4-flash-spark-${PORT}
    ;;
esac

if [[ ! -d "$MODEL_DIR" ]]; then
  echo "missing MODEL_DIR: $MODEL_DIR" >&2
  echo "run ./install.sh --profile ${PROFILE} first" >&2
  exit 1
fi

NAME=${NAME:-$DEFAULT_CONTAINER_NAME}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME_OVERRIDE:-${SERVED_MODEL_NAME:-$DEFAULT_SERVED_MODEL_NAME}}
THINKING=${THINKING_OVERRIDE:-${THINKING:-true}}
ENFORCE_EAGER=${ENFORCE_EAGER:-0}

MODEL_DIR="$MODEL_DIR" \
IMAGE="$IMAGE" \
NAME="$NAME" \
PORT="$PORT" \
HOST="$HOST" \
SERVED_MODEL_NAME="$SERVED_MODEL_NAME" \
CONTEXT_LENGTH="$CONTEXT_LENGTH" \
KV_CACHE_MEMORY_BYTES="$KV_CACHE_MEMORY_BYTES" \
KV_CACHE_DTYPE="$KV_CACHE_DTYPE" \
MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS" \
MAX_NUM_SEQS="$MAX_NUM_SEQS" \
GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
WATCHDOG_MIN_AVAILABLE_KB="$WATCHDOG_MIN_AVAILABLE_KB" \
ENFORCE_EAGER="$ENFORCE_EAGER" \
THINKING="$THINKING" \
SPECULATIVE_CONFIG="$SPECULATIVE_CONFIG" \
VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="$VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP" \
VLLM_TRITON_MLA_SPARSE_ALLOW_CUDAGRAPH="$VLLM_TRITON_MLA_SPARSE_ALLOW_CUDAGRAPH" \
"${SPARK_ROOT}/tools/launch_vllm_deepseek_v4_guarded.sh"

echo "server starting on http://${HOST}:${PORT}"
echo "container: ${NAME}"
