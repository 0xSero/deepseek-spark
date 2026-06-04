#!/usr/bin/env python3
"""Run deterministic long-context checks against an OpenAI-compatible server.

This runner deliberately does not import model or tokenizer code. It records
the server-reported token counts from the response `usage` block instead.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FILLER = (
    "This is deterministic context filler for a long-context retrieval test. "
    "It contains ordinary prose, numbers 0123456789, and repeated structure so "
    "the model must use the inserted needle rather than prior knowledge. "
)


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def request_chat(base_url: str, payload: dict[str, Any], timeout_s: int) -> tuple[dict[str, Any], float]:
    req = urllib.request.Request(
        base_url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw), time.perf_counter() - start


def prompt_for(target_tokens: int, chars_per_token: float, needle_depth: float) -> tuple[str, str]:
    # Keep the initial estimate conservative; vLLM returns the exact prompt token count.
    filler_chars = max(1024, int(target_tokens * chars_per_token))
    block = ""
    idx = 0
    while len(block) < filler_chars:
        idx += 1
        block += f"BLOCK {idx:06d}: {FILLER}\n"

    secret = f"SPARK-NEEDLE-{target_tokens}-73F9"
    pos = min(len(block), max(0, int(len(block) * needle_depth)))
    context = (
        block[:pos]
        + f"\nIMPORTANT NEEDLE: The secret code is {secret}.\n"
        + block[pos:]
    )
    prompt = (
        "You are doing a controlled long-context retrieval test.\n"
        "Find the exact secret code in the context. Answer with only the code.\n\n"
        "<context>\n"
        f"{context}"
        "</context>\n\n"
        "Question: What is the exact secret code?"
    )
    return prompt, secret


def calibrate_chars_per_token(base_url: str, model: str, timeout_s: int) -> float:
    prompt, _ = prompt_for(2048, 4.0, 0.5)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 1,
    }
    response, _ = request_chat(base_url, payload, timeout_s)
    prompt_tokens = response.get("usage", {}).get("prompt_tokens")
    if not isinstance(prompt_tokens, int) or prompt_tokens <= 0:
        return 4.0
    return len(prompt) / prompt_tokens


def run_one(
    base_url: str,
    model: str,
    target_tokens: int,
    chars_per_token: float,
    needle_depth: float,
    max_tokens: int,
    timeout_s: int,
) -> dict[str, Any]:
    prompt, secret = prompt_for(target_tokens, chars_per_token, needle_depth)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": max_tokens,
    }
    response, elapsed_s = request_chat(base_url, payload, timeout_s)
    message = response["choices"][0]["message"]
    content = message.get("content") or ""
    usage = response.get("usage", {})
    observed_prompt_tokens = usage.get("prompt_tokens")
    completion_tokens = usage.get("completion_tokens")
    prefill_tok_s = None
    decode_tok_s = None
    if isinstance(observed_prompt_tokens, int) and elapsed_s > 0:
        prefill_tok_s = observed_prompt_tokens / elapsed_s
    if isinstance(completion_tokens, int) and elapsed_s > 0:
        decode_tok_s = completion_tokens / elapsed_s
    return {
        "target_prompt_tokens": target_tokens,
        "observed_prompt_tokens": observed_prompt_tokens,
        "completion_tokens": completion_tokens,
        "needle_depth": needle_depth,
        "secret": secret,
        "content": content,
        "passed": secret in content,
        "finish_reason": response["choices"][0].get("finish_reason"),
        "elapsed_s": elapsed_s,
        "prefill_tok_s_including_decode": prefill_tok_s,
        "completion_tok_s_including_prefill": decode_tok_s,
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
        "response_id": response.get("id"),
        "system_fingerprint": response.get("system_fingerprint"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:18000")
    parser.add_argument("--model", default="DeepSeek-V4-Flash-Spark")
    parser.add_argument("--targets", default="8192,32768,65536,136000,186000")
    parser.add_argument("--needle-depth", type=float, default=0.72)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--timeout-s", type=int, default=900)
    parser.add_argument("--out-dir", default="runtime/evidence/context-evals")
    parser.add_argument("--label", default="")
    parser.add_argument("--chars-per-token", type=float, default=None)
    args = parser.parse_args()

    targets = [int(part.strip()) for part in args.targets.split(",") if part.strip()]
    out_dir = Path(args.out_dir) / (args.label or now_stamp())
    out_dir.mkdir(parents=True, exist_ok=True)

    started_at = datetime.now(timezone.utc).isoformat()
    chars_per_token = (
        args.chars_per_token
        if args.chars_per_token is not None
        else calibrate_chars_per_token(args.base_url, args.model, args.timeout_s)
    )
    summary: dict[str, Any] = {
        "condition": {
            "base_url": args.base_url,
            "model": args.model,
            "targets": targets,
            "needle_depth": args.needle_depth,
            "max_tokens": args.max_tokens,
            "timeout_s": args.timeout_s,
            "cwd": os.getcwd(),
            "started_at": started_at,
            "chars_per_token_calibration": chars_per_token,
        },
        "results": [],
    }

    print(json.dumps({"event": "calibrated", "chars_per_token": chars_per_token}), flush=True)
    for target in targets:
        print(json.dumps({"event": "start", "target_prompt_tokens": target}), flush=True)
        result = run_one(
            args.base_url,
            args.model,
            target,
            chars_per_token,
            args.needle_depth,
            args.max_tokens,
            args.timeout_s,
        )
        summary["results"].append(result)
        result_path = out_dir / f"needle-{target}.json"
        result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"event": "done", **result}, sort_keys=True), flush=True)

    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    (out_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"event": "summary", "path": str(out_dir / "summary.json")}), flush=True)
    return 0 if all(item["passed"] for item in summary["results"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
