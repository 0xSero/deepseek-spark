#!/usr/bin/env bash
set -euo pipefail

SPARK_ROOT=${SPARK_ROOT:-$HOME/spark}
MODEL_DIR=${MODEL_DIR:?Set MODEL_DIR to the DeepSeek V4 snapshot path on the Spark}
PORT=${PORT:-8002}
NAME=${NAME:-studio-deepseek-v4-flash-spark-${PORT}}
HOST=${HOST:-100.83.190.2}
CONTEXT_LENGTH=${CONTEXT_LENGTH:-512}
MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS:-256}
MAX_NUM_SEQS=${MAX_NUM_SEQS:-1}
KV_CACHE_MEMORY_BYTES=${KV_CACHE_MEMORY_BYTES:-64M}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE:-fp8}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION:-0.70}
WATCHDOG_MIN_AVAILABLE_KB=${WATCHDOG_MIN_AVAILABLE_KB:-2097152}
IMAGE=${IMAGE:-vllm-node-dsv4-cutlass451:latest}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-DeepSeek-V4-Flash-Spark}
WATCHDOG_LOG=${WATCHDOG_LOG:-${SPARK_ROOT}/logs/${NAME}.watchdog.log}
PATCHER=${PATCHER:-${SPARK_ROOT}/serve/patch_vllm_k160_native.py}
ENABLE_TOOLS=${ENABLE_TOOLS:-1}
ENABLE_REASONING=${ENABLE_REASONING:-1}
ENABLE_PREFIX_CACHING=${ENABLE_PREFIX_CACHING:-1}
ENFORCE_EAGER=${ENFORCE_EAGER:-0}
THINKING=${THINKING:-false}
MOE_BACKEND=${MOE_BACKEND:-}
ATTENTION_CONFIG=${ATTENTION_CONFIG:-}
SPECULATIVE_CONFIG=${SPECULATIVE_CONFIG:-}
EXTRA_ARGS=${EXTRA_ARGS:-}

docker rm -f "$NAME" >/dev/null 2>&1 || true
mkdir -p "$(dirname "$WATCHDOG_LOG")"
: > "$WATCHDOG_LOG"

(
  echo "WATCHDOG_START $(date -Is) threshold_kb=${WATCHDOG_MIN_AVAILABLE_KB} name=${NAME}"
  while true; do
    if docker ps -a --format "{{.Names}}" | grep -qx "$NAME"; then
      running=$(docker inspect -f "{{.State.Running}}" "$NAME" 2>/dev/null || echo false)
      if [ "$running" != true ]; then
        echo "WATCHDOG_EXIT_NOT_RUNNING $(date -Is)"
        exit 0
      fi
      available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
      if [ "$available_kb" -lt "$WATCHDOG_MIN_AVAILABLE_KB" ]; then
        echo "WATCHDOG_KILL $(date -Is) mem_available_kb=${available_kb}"
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        exit 0
      fi
    fi
    sleep 1
  done
) >> "$WATCHDOG_LOG" 2>&1 &
echo $! > "${SPARK_ROOT}/logs/${NAME}.watchdog.pid"

args=(
  vllm serve "$MODEL_DIR"
  --served-model-name "$SERVED_MODEL_NAME"
  --host "$HOST"
  --port "$PORT"
  --trust-remote-code
  --tensor-parallel-size 1
  --pipeline-parallel-size 1
  --kv-cache-dtype "$KV_CACHE_DTYPE"
  --kv-cache-memory-bytes "$KV_CACHE_MEMORY_BYTES"
  --block-size 256
  --max-model-len "$CONTEXT_LENGTH"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --distributed-executor-backend mp
  --tokenizer-mode deepseek_v4
  --load-format safetensors
  --disable-uvicorn-access-log
)

if [[ "$ENABLE_PREFIX_CACHING" == "1" ]]; then
  args+=(--enable-prefix-caching)
fi
if [[ "$ENABLE_TOOLS" == "1" ]]; then
  args+=(--tool-call-parser deepseek_v4 --enable-auto-tool-choice)
fi
if [[ "$ENABLE_REASONING" == "1" ]]; then
  args+=(
    --reasoning-parser deepseek_v4
    --reasoning-config '{"reasoning_parser":"deepseek_v4","reasoning_start_str":"<think>","reasoning_end_str":"</think>"}'
    --default-chat-template-kwargs "{\"thinking\":${THINKING}}"
  )
fi
if [[ -n "$MOE_BACKEND" ]]; then
  args+=(--moe-backend "$MOE_BACKEND")
fi
if [[ -n "$ATTENTION_CONFIG" ]]; then
  args+=(--attention-config "$ATTENTION_CONFIG")
fi
if [[ "$ENFORCE_EAGER" == "1" ]]; then
  args+=(--enforce-eager)
else
  args+=(--compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}')
fi
if [[ -n "$SPECULATIVE_CONFIG" ]]; then
  args+=(--speculative-config "$SPECULATIVE_CONFIG")
fi
if [[ -n "$EXTRA_ARGS" ]]; then
  # shellcheck disable=SC2206
  extra_args_array=($EXTRA_ARGS)
  args+=("${extra_args_array[@]}")
fi

docker run -d \
  --name "$NAME" \
  --entrypoint bash \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v ${SPARK_ROOT}:${SPARK_ROOT} \
  -e HF_HOME=${SPARK_ROOT}/models/hf-cache \
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e VLLM_TRITON_MLA_SPARSE=1 \
  -e VLLM_TRITON_MLA_SPARSE_ALLOW_CUDAGRAPH="${VLLM_TRITON_MLA_SPARSE_ALLOW_CUDAGRAPH:-1}" \
  -e VLLM_ENABLE_DEEPSEEK_V4_MHC_WARMUP="${VLLM_ENABLE_DEEPSEEK_V4_MHC_WARMUP:-1}" \
  -e VLLM_DEEPSEEK_V4_MHC_WARMUP_TOKEN_SIZES="${VLLM_DEEPSEEK_V4_MHC_WARMUP_TOKEN_SIZES:-}" \
  -e VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="${VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP:-1}" \
  -e FLASHINFER_DISABLE_VERSION_CHECK=1 \
  -e TILELANG_CLEANUP_TEMP_FILES=1 \
  -e DG_JIT_USE_NVRTC=0 \
  -e DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc \
  -e NCCL_IB_DISABLE=1 \
  -e NCCL_DEBUG=WARN \
  -e K160_DISABLE_CUTEDSL="${K160_DISABLE_CUTEDSL:-0}" \
  -e CUTEDSL_VERSION="${CUTEDSL_VERSION:-}" \
  -e VLLM_MXFP4_MARLIN_DEEPGEMM_LAYERS="${VLLM_MXFP4_MARLIN_DEEPGEMM_LAYERS:-}" \
  -e PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}" \
  "$IMAGE" \
  -lc "python3 '$PATCHER' && exec $(printf '%q ' "${args[@]}")"
