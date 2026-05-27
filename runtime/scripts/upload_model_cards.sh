#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
PYTHON=${PYTHON:-python3}

if [[ -z "${HF_TOKEN:-}" && -z "${HF_TOKEN_FILE:-}" ]]; then
  echo "set HF_TOKEN or HF_TOKEN_FILE with write access to the 0xSero model repos" >&2
  exit 2
fi

"$PYTHON" - <<'PY'
import os
import sys
from pathlib import Path

try:
    from huggingface_hub import HfApi
except ImportError:
    print("install huggingface_hub first: python3 -m pip install -U huggingface_hub", file=sys.stderr)
    raise

repo_root = Path(os.environ.get("REPO_ROOT", ".")).resolve()
token = os.environ.get("HF_TOKEN")
token_file = os.environ.get("HF_TOKEN_FILE")
if not token and token_file:
    token = Path(token_file).read_text().strip()
if not token:
    raise SystemExit("missing HF_TOKEN or HF_TOKEN_FILE")

api = HfApi(token=token)

uploads = [
    (
        "0xSero/DeepSeek-V4-Flash-162B",
        repo_root / "model-cards" / "Deepseek-V4-Flash-162B-REAP.md",
    ),
    (
        "0xSero/DeepSeek-V4-Flash-180B",
        repo_root / "model-cards" / "Deepseek-V4-Flash-180B-REAP.md",
    ),
]

for repo_id, local_path in uploads:
    api.upload_file(
        repo_id=repo_id,
        repo_type="model",
        path_or_fileobj=str(local_path),
        path_in_repo="README.md",
        commit_message="Update DGX Spark 200K serving recipe",
    )
    print(f"updated {repo_id}/README.md")
PY
