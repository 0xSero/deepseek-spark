#!/usr/bin/env bash
set -euo pipefail

SPARK_ROOT=${SPARK_ROOT:-${HOME}/spark}
BUILD_ROOT=${BUILD_ROOT:-${SPARK_ROOT}/sources}
SPARK_VLLM_REPO=${SPARK_VLLM_REPO:-https://github.com/eugr/spark-vllm-docker.git}
SPARK_VLLM_PR=${SPARK_VLLM_PR:-219}
SPARK_VLLM_REF=${SPARK_VLLM_REF:-}
SPARK_VLLM_DIR=${SPARK_VLLM_DIR:-${BUILD_ROOT}/spark-vllm-docker}
TARGET_IMAGE=${TARGET_IMAGE:-vllm-node-dsv4:latest}
VLLM_REPO=${VLLM_REPO:-https://github.com/jasl/vllm.git}
VLLM_REF=${VLLM_REF:-codex/ds4-sm120-min-enable}
BUILD_JOBS=${BUILD_JOBS:-16}
GPU_ARCH=${GPU_ARCH:-12.1a}
DOCKER_BUILD_NETWORK=${DOCKER_BUILD_NETWORK:-host}

mkdir -p "$BUILD_ROOT"

if [[ ! -d "${SPARK_VLLM_DIR}/.git" ]]; then
  rm -rf "$SPARK_VLLM_DIR"
  git clone "$SPARK_VLLM_REPO" "$SPARK_VLLM_DIR"
fi

cd "$SPARK_VLLM_DIR"
git fetch origin --tags --force

if [[ -n "$SPARK_VLLM_REF" ]]; then
  git checkout "$SPARK_VLLM_REF"
else
  git fetch origin "pull/${SPARK_VLLM_PR}/head:pr-${SPARK_VLLM_PR}" --force
  git checkout "pr-${SPARK_VLLM_PR}"
fi

./build-and-copy.sh \
  -t "$TARGET_IMAGE" \
  --gpu-arch "$GPU_ARCH" \
  --vllm-repo "$VLLM_REPO" \
  --vllm-ref "$VLLM_REF" \
  --tf5 \
  --network "$DOCKER_BUILD_NETWORK" \
  -j "$BUILD_JOBS"

docker image inspect "$TARGET_IMAGE" >/dev/null
echo "IMAGE_READY $TARGET_IMAGE"
