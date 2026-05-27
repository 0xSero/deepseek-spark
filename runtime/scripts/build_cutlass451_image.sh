#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE=${BASE_IMAGE:-vllm-node-dsv4:latest}
TARGET_IMAGE=${TARGET_IMAGE:-vllm-node-dsv4-cutlass451:latest}
NAME=${NAME:-vllm-node-dsv4-cutlass451-build}

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --entrypoint bash "$BASE_IMAGE" -lc '
  set -euo pipefail
  pip install -U --no-cache-dir "nvidia-cutlass-dsl[cu13]==4.5.1"
  python3 - <<PY
import importlib.metadata as m
print("nvidia-cutlass-dsl", m.version("nvidia-cutlass-dsl"))
print("vllm", m.version("vllm"))
PY
  sleep infinity
' >/dev/null

for _ in $(seq 1 240); do
  if docker logs "$NAME" 2>&1 | grep -q "Successfully installed"; then
    break
  fi
  if ! docker inspect -f "{{.State.Running}}" "$NAME" 2>/dev/null | grep -q true; then
    docker logs "$NAME" >&2 || true
    exit 1
  fi
  sleep 2
done

docker logs "$NAME" 2>&1 | tail -80
docker commit "$NAME" "$TARGET_IMAGE" >/dev/null
docker rm -f "$NAME" >/dev/null
docker run --rm --entrypoint bash "$TARGET_IMAGE" -lc '
  python3 - <<PY
import importlib.metadata as m
print("nvidia-cutlass-dsl", m.version("nvidia-cutlass-dsl"))
print("vllm", m.version("vllm"))
PY
'
echo "IMAGE_READY $TARGET_IMAGE"
