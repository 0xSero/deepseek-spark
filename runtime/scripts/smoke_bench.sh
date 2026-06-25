#!/usr/bin/env bash
set -euo pipefail

BASE_URL=${BASE_URL:-http://0.0.0.0:8000}
MODEL=${MODEL:-DeepSeek-V4-Flash-Spark}

python3 - <<PY
import json, urllib.request
payload = {
    "model": "${MODEL}",
    "messages": [{"role": "user", "content": "Say exactly: REAP online."}],
    "temperature": 0,
    "max_tokens": 16,
}
req = urllib.request.Request(
    "${BASE_URL}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(urllib.request.urlopen(req, timeout=120).read().decode())
PY
