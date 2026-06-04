# 2026-06-02 — DS0 intended warm baseline (control, pre-custom-systems)

## 🏁 SCORE TO BEAT: 30.2 tok/s decode (batch=1, warm, median of 5)
Any custom/warpgate system must clear **30.2 tok/s** median decode under the same warm
protocol (2 warmup discarded + 5 timed reps, temp=0, single stream) to count as a win.
Secondary: TTFT 1685 ms, e2e 22.1 tok/s. Stock k160-mtp2-200k, 6 GB watchdog untouched.

Rig `spark-2949` (GB10, ~121 GB unified). Goal: a clean **control** baseline for the
stock DS0 serving path before evaluating any custom/warpgate systems.

## Incident context
The prior session OOM'd the whole rig. Root cause: the `sero-control-k160-8040` launch
came up via the heavier **ds0-dualwarp** manual `docker` path **and** the OOM watchdog was
overridden from its intended 6 GB floor down to 1 KB (effectively off). With no floor, the
fp8 weight load drove `MemAvailable` to 0 and the kernel OOM-killer reaped the rig.
Fix going forward: **never override the watchdog**; load the stock DS0 path as intended.

## What was run (intended path)
- `cd /home/frosty40/ds0 && set -a && source spark-local.env && set +a && ./setup.sh model k160`
- Profile `k160-mtp2-200k` (unmodified): 180B fp8, `GPU_MEMORY_UTILIZATION=0.88`,
  `KV_CACHE_MEMORY_BYTES=6G` fp8, `MAX_NUM_SEQS=1`, `CONTEXT_LENGTH=200000`,
  MTP2 spec-decode, **`WATCHDOG_MIN_AVAILABLE_KB=6291456` (6 GB floor, untouched)**.
- Container `studio-deepseek-v4-flash-spark-18000` on `127.0.0.1:18000`.

## Load behavior (safe)
- Watchdog confirmed live: `WATCHDOG_START ... threshold_kb=6291456`.
- `MemAvailable` floor during load: 117 GB → ~9 GB free (weights ~97 GB + 6 GB KV).
  Stayed ~3 GB above the 6 GB watchdog floor; watchdog never fired.
- Came up HEALTHY; `Initial free memory 114.01 GiB, reserved 6.0 GiB for KV`,
  `GPU KV cache size: 537,516 tokens`, max concurrency 2.69x @ 200k.

## Warm baseline — single stream, temp=0, 2 warmup discarded + 5 timed reps
`baseline_bench.py` (prompt: "Count from 1 to 50, one number per line, then stop.", max_tokens=256)

| metric | median (5 reps) | spread |
|---|---|---|
| decode rate | **30.2 tok/s** | 29.2–30.8 (mean 30.2) |
| TTFT | 1685 ms | 1596–1864 ms |
| e2e rate | 22.1 tok/s | 21.3–22.5 |
| completion | 137 tok | — |

Memory steady at 9.5 → 9.4 GB free across the whole bench (never threatened the floor).

## Takeaway
Stock DS0 k160-mtp2-200k serves cleanly with ~3 GB headroom and a stable **~30 tok/s
batch-1 decode** control. The W8A8 block-FP8 GEMM is the path warpgate optimizes; any
custom-system comparison should beat this 30.2 tok/s median under the same warm protocol.
