#!/usr/bin/env bash
set -euo pipefail

PROFILE=${PROFILE:-k160-mtp2-200k}
SPARK_ROOT=${SPARK_ROOT:-${HOME}/spark}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HF_HOME=${HF_HOME:-${SPARK_ROOT}/models/hf-cache}
IMAGE_REF=${IMAGE_REF:-ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27}
LOCAL_IMAGE=${LOCAL_IMAGE:-vllm-node-dsv4-cutlass451:latest}
BASE_IMAGE=${BASE_IMAGE:-vllm-node-dsv4:latest}
AUTO_BUILD_BASE_IMAGE=${AUTO_BUILD_BASE_IMAGE:-1}
LAUNCH=0
GHCR_LOGGED_IN=0

cleanup() {
  if [[ "$GHCR_LOGGED_IN" == "1" ]]; then
    docker logout ghcr.io >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE=${2:?missing profile name}
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

CONFIG="${REPO_ROOT}/configs/${PROFILE}.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "missing profile config: $CONFIG" >&2
  exit 2
fi

mkdir -p "${SPARK_ROOT}/serve" "${SPARK_ROOT}/tools" "${SPARK_ROOT}/models" "${SPARK_ROOT}/logs"
install -m 0755 "${REPO_ROOT}/scripts/patch_vllm_reap_gb10.py" "${SPARK_ROOT}/serve/patch_vllm_k160_native.py"
install -m 0755 "${REPO_ROOT}/scripts/launch_vllm_deepseek_v4_guarded.sh" "${SPARK_ROOT}/tools/launch_vllm_deepseek_v4_guarded.sh"

set -a
# shellcheck source=/dev/null
source "$CONFIG"
set +a

echo "PROFILE=${PROFILE}"
echo "MODEL_REPO=${MODEL_REPO}"
if [[ -n "${MODEL_REPO_LEGACY:-}" ]]; then
  echo "MODEL_REPO_LEGACY=${MODEL_REPO_LEGACY}"
fi
echo "MODEL_REVISION=${MODEL_REVISION}"

if ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  if [[ -n "$IMAGE_REF" && "$IMAGE_REF" == ghcr.io/* && -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_USER:-0xSero}" --password-stdin >/dev/null
    GHCR_LOGGED_IN=1
  fi

  if [[ -n "$IMAGE_REF" ]] && docker pull "$IMAGE_REF"; then
    docker tag "$IMAGE_REF" "$LOCAL_IMAGE"
  elif docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    BASE_IMAGE="$BASE_IMAGE" TARGET_IMAGE="$LOCAL_IMAGE" "${REPO_ROOT}/scripts/build_cutlass451_image.sh"
  elif [[ "$AUTO_BUILD_BASE_IMAGE" == "1" ]]; then
    TARGET_IMAGE="$BASE_IMAGE" "${REPO_ROOT}/scripts/build_dsv4_base_image.sh"
    BASE_IMAGE="$BASE_IMAGE" TARGET_IMAGE="$LOCAL_IMAGE" "${REPO_ROOT}/scripts/build_cutlass451_image.sh"
  else
    echo "could not find $LOCAL_IMAGE, and base $BASE_IMAGE is unavailable" >&2
    echo "set IMAGE_REF to a registry image, preinstall $BASE_IMAGE, or leave AUTO_BUILD_BASE_IMAGE=1" >&2
    exit 1
  fi
fi

snapshot_dir_for_repo() {
  local repo=$1
  echo "${HF_HOME}/models--${repo//\//--}/snapshots/${MODEL_REVISION}"
}

SNAPSHOT_DIR=$(snapshot_dir_for_repo "$MODEL_REPO")
if [[ ! -d "$SNAPSHOT_DIR" && -n "${MODEL_REPO_LEGACY:-}" ]]; then
  LEGACY_SNAPSHOT_DIR=$(snapshot_dir_for_repo "$MODEL_REPO_LEGACY")
  if [[ -d "$LEGACY_SNAPSHOT_DIR" ]]; then
    echo "using cached legacy repo snapshot: ${MODEL_REPO_LEGACY}"
    SNAPSHOT_DIR="$LEGACY_SNAPSHOT_DIR"
  fi
fi
if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  VENV="${SPARK_ROOT}/tools/hf-download-venv"
  if [[ ! -x "${VENV}/bin/python" ]]; then
    python3 -m venv "$VENV"
  fi
  "${VENV}/bin/python" -m pip install -U pip >/dev/null
  "${VENV}/bin/python" -m pip install -U huggingface_hub hf_transfer >/dev/null
  HF_HOME="$HF_HOME" HF_HUB_ENABLE_HF_TRANSFER=1 MODEL_REPO="$MODEL_REPO" MODEL_REVISION="$MODEL_REVISION" "${VENV}/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ["MODEL_REPO"],
    revision=os.environ["MODEL_REVISION"],
    cache_dir=os.environ["HF_HOME"],
    token=os.environ.get("HF_TOKEN") or None,
    resume_download=True,
)
PY
fi

SNAPSHOT_DIR=$(snapshot_dir_for_repo "$MODEL_REPO")
if [[ ! -d "$SNAPSHOT_DIR" && -n "${MODEL_REPO_LEGACY:-}" ]]; then
  LEGACY_SNAPSHOT_DIR=$(snapshot_dir_for_repo "$MODEL_REPO_LEGACY")
  if [[ -d "$LEGACY_SNAPSHOT_DIR" ]]; then
    SNAPSHOT_DIR="$LEGACY_SNAPSHOT_DIR"
  fi
fi

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  echo "model snapshot was not found after download: $SNAPSHOT_DIR" >&2
  exit 1
fi

echo "MODEL_DIR=${SNAPSHOT_DIR}"
echo "IMAGE=${LOCAL_IMAGE}"

if [[ "$LAUNCH" == "1" ]]; then
  PROFILE="$PROFILE" MODEL_DIR="$SNAPSHOT_DIR" IMAGE="$LOCAL_IMAGE" "${REPO_ROOT}/scripts/serve_profile.sh"
else
  echo "install complete. launch with: PROFILE=${PROFILE} MODEL_DIR='${SNAPSHOT_DIR}' IMAGE=${LOCAL_IMAGE} ${REPO_ROOT}/scripts/serve_profile.sh"
fi
