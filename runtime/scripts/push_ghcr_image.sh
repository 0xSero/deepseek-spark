#!/usr/bin/env bash
set -euo pipefail

SOURCE_IMAGE=${SOURCE_IMAGE:-vllm-node-dsv4-cutlass451:latest}
TARGET_IMAGE=${TARGET_IMAGE:-ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27}
GITHUB_USER=${GITHUB_USER:-0xSero}

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "set GITHUB_TOKEN with write:packages/read:packages scope" >&2
  exit 2
fi

docker image inspect "$SOURCE_IMAGE" >/dev/null
docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin >/dev/null
docker push "$TARGET_IMAGE"
docker logout ghcr.io >/dev/null 2>&1 || true
