#!/usr/bin/env python3
"""Warm-then-measure single-stream decode baseline for DeepSeek-V4-Flash-Spark.

Protocol: discard N warmup reps, then time M reps. Streaming, temp=0 (deterministic).
Reports TTFT and steady-state decode tok/s (the metric the W8A8 GEMM work moves).
Single concurrency to match MAX_NUM_SEQS=1; small gen to stay well above the 6 GB floor.
"""
import json, time, urllib.request, statistics, sys, os

BASE = os.environ.get("BASE", "http://127.0.0.1:18000")
MODEL = "DeepSeek-V4-Flash-Spark"
PROMPT = os.environ.get("PROMPT", "Count from 1 to 50, one number per line, then stop.")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
WARMUP = int(os.environ.get("WARMUP", "2"))
REPS = int(os.environ.get("REPS", "5"))
TEMP = float(os.environ.get("TEMP", "0"))
SEED = os.environ.get("SEED")  # optional; set for reproducible temp>0 sampling


def one_rep():
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "temperature": TEMP,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if SEED is not None:
        payload["seed"] = int(SEED)
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    ttft = None
    last = t0
    completion_tokens = 0
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            choices = chunk.get("choices") or []
            if choices:
                delta = choices[0].get("delta", {})
                if delta.get("content"):
                    now = time.perf_counter()
                    if ttft is None:
                        ttft = now - t0
                    last = now
            usage = chunk.get("usage")
            if usage:
                completion_tokens = usage.get("completion_tokens", completion_tokens)
    total = last - t0
    # steady-state decode: tokens after the first, over the time after first token
    decode_window = last - (t0 + (ttft or 0))
    decode_tps = (completion_tokens - 1) / decode_window if decode_window > 0 and completion_tokens > 1 else 0.0
    e2e_tps = completion_tokens / total if total > 0 else 0.0
    return {"ttft": ttft or 0.0, "total": total, "ctoks": completion_tokens,
            "decode_tps": decode_tps, "e2e_tps": e2e_tps}


def main():
    print(f"warmup x{WARMUP} (discarded)...", flush=True)
    for i in range(WARMUP):
        r = one_rep()
        print(f"  warmup {i+1}: {r['ctoks']} toks, {r['decode_tps']:.1f} tok/s decode", flush=True)
    print(f"\nmeasuring x{REPS}...", flush=True)
    reps = []
    for i in range(REPS):
        r = one_rep()
        reps.append(r)
        print(f"  rep {i+1}: ttft={r['ttft']*1000:.0f}ms  {r['ctoks']} toks  "
              f"decode={r['decode_tps']:.1f} tok/s  e2e={r['e2e_tps']:.1f} tok/s", flush=True)

    def med(k):
        return statistics.median(x[k] for x in reps)
    def mean(k):
        return statistics.mean(x[k] for x in reps)
    print("\n=== BASELINE (median over %d reps) ===" % REPS)
    print(f"  TTFT:        {med('ttft')*1000:.0f} ms")
    print(f"  decode rate: {med('decode_tps'):.1f} tok/s  (mean {mean('decode_tps'):.1f})")
    print(f"  e2e rate:    {med('e2e_tps'):.1f} tok/s")
    print(f"  completion:  {int(med('ctoks'))} tokens")
    print(json.dumps({"model": MODEL, "prompt": PROMPT, "max_tokens": MAX_TOKENS,
                      "temp": TEMP, "seed": SEED, "warmup": WARMUP, "reps": REPS,
                      "median": {k: med(k) for k in ("ttft","total","decode_tps","e2e_tps")},
                      "raw": reps}))


if __name__ == "__main__":
    sys.exit(main())
