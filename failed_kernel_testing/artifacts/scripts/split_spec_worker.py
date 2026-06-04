#!/usr/bin/env python3
"""Minimal remote draft worker endpoint for split speculative decode.

Run this on the RTX 3090 or RTX 4080 host in front of a local OpenAI-compatible
draft model. It gives Spark a stable health/probe/draft contract before the
production verifier path exists.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse


WORKER_NAME = os.environ.get("SPLIT_SPEC_WORKER_NAME", "split-spec-worker")
BACKEND_URL = os.environ.get("SPLIT_SPEC_BACKEND_URL", "").rstrip("/")
MODEL = os.environ.get("SPLIT_SPEC_MODEL", "")
PORT = int(os.environ.get("SPLIT_SPEC_PORT", "8108"))
HOST = os.environ.get("SPLIT_SPEC_HOST", "0.0.0.0")
REQUEST_TIMEOUT_S = float(os.environ.get("SPLIT_SPEC_REQUEST_TIMEOUT_S", "120"))


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def gpu_summary() -> str:
    override = os.environ.get("SPLIT_SPEC_GPU")
    if override:
        return override
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    return "; ".join(lines) if lines else "unknown"


def ready() -> bool:
    if env_flag("SPLIT_SPEC_READY", False):
        return True
    return bool(BACKEND_URL and MODEL)


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0"))
    raw = handler.rfile.read(length) if length else b"{}"
    return json.loads(raw.decode("utf-8"))


def completion_tokens(response: dict[str, Any], text: str) -> int:
    usage = response.get("usage")
    if isinstance(usage, dict):
        value = usage.get("completion_tokens")
        if isinstance(value, int) and value >= 0:
            return value
    return max(1, len(text.split()))


def extract_text(response: dict[str, Any]) -> str:
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0]
    if not isinstance(first, dict):
        return ""
    message = first.get("message")
    if isinstance(message, dict) and isinstance(message.get("content"), str):
        return message["content"]
    text = first.get("text")
    return text if isinstance(text, str) else ""


def call_backend(payload: dict[str, Any]) -> dict[str, Any]:
    if not BACKEND_URL or not MODEL:
        return {
            "ready": False,
            "error": "Set SPLIT_SPEC_BACKEND_URL and SPLIT_SPEC_MODEL on the RTX worker.",
        }

    prompt = str(payload.get("prompt", "Say exactly: split spec online."))
    max_tokens = int(payload.get("max_tokens", 64))
    temperature = payload.get("temperature", 0)
    request = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    req = urllib.request.Request(
        BACKEND_URL + "/v1/chat/completions",
        data=json.dumps(request).encode("utf-8"),
        headers={"Accept": "application/json", "Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
        raw = resp.read().decode("utf-8")
    elapsed_s = max(time.perf_counter() - start, 1e-9)
    response = json.loads(raw)
    text = extract_text(response)
    tokens = completion_tokens(response, text)
    tok_s = tokens / elapsed_s
    return {
        "ready": True,
        "worker": WORKER_NAME,
        "model": MODEL,
        "candidate_text": text,
        "candidate_token_ids": None,
        "completion_tokens": tokens,
        "elapsed_s": elapsed_s,
        "measured_decode_tok_s": tok_s,
        "accepted_by_spark": False,
        "protocol_note": "Text draft only. Spark token-ID verification is required before acceptance.",
    }


def health_payload() -> dict[str, Any]:
    configured = bool(BACKEND_URL and MODEL)
    capabilities = ["health"]
    if configured:
        capabilities.extend(["openai-chat-proxy", "text-draft-probe"])
    token_id_ready = False
    reported_decode = os.environ.get("SPLIT_SPEC_DECODE_TOK_S")
    payload: dict[str, Any] = {
        "ok": True,
        "ready": ready(),
        "worker": WORKER_NAME,
        "role": "draft-decode-worker",
        "protocol_version": 1,
        "gpu": gpu_summary(),
        "backend_url": BACKEND_URL or None,
        "model": MODEL or None,
        "capabilities": capabilities,
        "token_id_acceptance_ready": token_id_ready,
        "token_id_acceptance_note": "This stub returns text drafts only; Spark-side token-ID verification is not implemented here.",
    }
    if reported_decode:
        try:
            payload["measured_decode_tok_s"] = float(reported_decode)
        except ValueError:
            payload["decode_tok_s_error"] = "SPLIT_SPEC_DECODE_TOK_S is not a float"
    return payload


class Handler(BaseHTTPRequestHandler):
    server_version = "split-spec-worker/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path in {"/health", "/v1/spec/capabilities"}:
            json_response(self, 200, health_payload())
            return
        json_response(self, 404, {"ok": False, "error": f"unknown path: {path}"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path not in {"/v1/spec/probe", "/v1/spec/draft"}:
            json_response(self, 404, {"ok": False, "error": f"unknown path: {path}"})
            return
        try:
            payload = read_json(self)
            result = call_backend(payload)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            json_response(
                self,
                502,
                {
                    "ready": False,
                    "error": "backend HTTP error",
                    "status": exc.code,
                    "body": raw,
                },
            )
            return
        except (OSError, TimeoutError, json.JSONDecodeError, ValueError) as exc:
            json_response(self, 502, {"ready": False, "error": str(exc)})
            return

        if not result.get("ready"):
            json_response(self, 501, result)
            return
        json_response(self, 200, result)


def main() -> int:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"{WORKER_NAME} listening on http://{HOST}:{PORT}", flush=True)
    print(f"backend={BACKEND_URL or 'not configured'} model={MODEL or 'not configured'}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
