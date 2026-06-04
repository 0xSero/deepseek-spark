# 2026-05-31 Local K160 Baseline

Working directory: `/home/frosty40/ds0`
Rig: `spark-2949` / NVIDIA GB10
Run label: local baseline of recorded `k160-mtp2-200k` condition

## Condition

Source profile:

```text
runtime/configs/k160-mtp2-200k.env
sha256: 4273d40f4376ea69ed7153e2d8f351bda81aacd30f6813544aa0937ec345f348
```

Resolved launch:

```text
MODEL_REPO=0xSero/DeepSeek-V4-Flash-180B
MODEL_REVISION=7c360e1cd4a5168099dbc54d16d929bf6df04990
SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
CONTEXT_LENGTH=200000
KV_CACHE_MEMORY_BYTES=6G
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=1
GPU_MEMORY_UTILIZATION=0.88
KV_CACHE_DTYPE=fp8
THINKING=true
SPECULATIVE_CONFIG={"method":"deepseek_mtp","num_speculative_tokens":2}
```

Other source hashes:

```text
runtime/scripts/launch_vllm_deepseek_v4_guarded.sh sha256: 4c0762d340ddd18159c1aaeca5daf872549049f8bdda6ed3e2b1511b8f72448c
runtime/scripts/patch_vllm_reap_gb10.py sha256: 9e538f29fd92504dee7df133965211b31037902ada5ede1e95852a24df712757
scripts/studio_model_entrypoint.sh sha256: 97b9d442669751a276ae3fbc7698171bcf3aff91dd106c0beaf1987e324b30ad
git HEAD: 862b0126adce37bffa32cd6526ae0f6cc4e361aa
```

## Commands

```bash
./preflight.sh
bash -lc 'set -euo pipefail; set -a; source ./spark-local.env; set +a; ./setup.sh api k160'
bash -lc 'set -euo pipefail; set -a; source ./spark-local.env; source /home/frosty40/spark/deepseek-spark/runtime/studio.env; set +a; EXPECTED_MODEL=DeepSeek-V4-Flash-Spark CONTROLLER_URL=http://127.0.0.1:${CONTROLLER_PORT} INFERENCE_URL=http://127.0.0.1:${INFERENCE_PORT} STREAM_TIMEOUT_SECONDS=240 BENCHMARK_TIMEOUT_SECONDS=240 ./scripts/healthcheck.sh'
BASE_URL=http://127.0.0.1:18000 MODEL=DeepSeek-V4-Flash-Spark ./runtime/scripts/smoke_bench.sh
curl -fsS --max-time 240 -H "x-api-key: ${VLLM_STUDIO_API_KEY}" -X POST "http://127.0.0.1:${CONTROLLER_PORT}/benchmark?prompt_tokens=128&max_tokens=32"
python3 runtime/scripts/split_spec_probe.py --allow-no-worker --json
```

## Results

Preflight after local diagnostic fixes:

```text
docker+nvidia runtime PASS
bun PASS (/home/frosty40/.bun/bin/bun)
controller :18080 PASS
recipes preloaded PASS (2)
runtime image PASS
180B weights PASS
inference port 18000 PASS (free)
nvme free PASS (359G)
GB10 unified mem PASS (116G available)
GPU users: none
```

Healthcheck:

```text
deepseek-v4-flash-spark:running
deepseek-v4-flash-spark-mini:stopped
inference health: pass
inference model: DeepSeek-V4-Flash-Spark
docker launch flags: ok
direct streaming: ok
controller streaming: ok
benchmark write path: ok
```

Smoke:

```json
{"model":"DeepSeek-V4-Flash-Spark","content":"REAP online.","prompt_tokens":11,"completion_tokens":35}
```

Small controller benchmark, cold-ish first run after healthcheck:

```json
{"prompt_tokens":135,"completion_tokens":32,"total_time_s":8.67,"generation_tps":3.7}
```

Small controller benchmark, second run after warmup:

```json
{"prompt_tokens":135,"completion_tokens":32,"total_time_s":1.8,"generation_tps":17.8}
```

Controller peak metrics after the warm run:

```json
{"prefill_tps":2100.3534925325166,"generation_tps":23.573451893588416,"ttft_ms":159.05499458312988,"total_tokens":40,"total_requests":2}
```

Split-spec probe after correcting the example Spark URL to this rig:

```json
{"spark_ok":true,"spark_base_url":"http://127.0.0.1:18000","model_match":true,"selected_worker":null}
```

## Runtime Signals

```text
Model loading took 96.66 GiB memory and 204.196576 seconds
Graph capturing finished in 20 secs, took 1.15 GiB
GPU KV cache size: 537,516 tokens
Maximum concurrency for 200,000 tokens per request: 2.69x
```

Tile/kernel observations:

```text
TileLang compiled mhc_pre_big_fuse_with_norm_tilelang, mhc_post_tilelang, hc_head_fuse_tilelang, and mhc_fused_tilelang.
GB10 W8A8 Block FP8 configs were found for N=1536,K=4096; N=4096,K=4096; and N=8192,K=1024.
GB10 W8A8 Block FP8 configs were missing for N=32768,K=1024; N=4096,K=8192; and N=4096,K=2048, falling back to default configs.
First inference still triggered Triton JIT for prefill metadata, FP8 GEMM/einsum, paged attention, and speculative rejection kernels.
```

Spec decode observations from short smoke/benchmark traffic:

```text
Avg draft acceptance rate ranged from 42.0% to 75.0% on small prompts.
Mean acceptance length ranged from 1.84 to 2.50.
```

## Debug Findings

- `preflight.sh` had three local diagnostic bugs: Docker GPU runtime detection used a fragile `docker info | grep`, recipe counting used line count on minified JSON, and GB10 `nvidia-smi` memory `N/A` crashed arithmetic. These are fixed locally.
- `runtime/scripts/smoke_bench.sh` used `max_tokens=16`, which is too small for the configured thinking profile; it returned `content:null` because the budget was spent in `reasoning`. It now uses 96 tokens and asserts exact content.
- Split-spec worker selection previously ignored `selection.require_token_ids_for_acceptance`; it could select a text-only worker based on a decode score. The selector now requires token-ID capability when the config requires it, and the current stub no longer advertises token-ID readiness.
- `runtime/configs/split-spec-decode.example.json` pointed Spark at an upstream Tailscale URL `<spark-tailnet-ip>:8000`; on this rig that timed out. The example now points Spark-side probing at `127.0.0.1:18000`.

## Next Baseline Work

1. Add a warmup shape pass that covers the JIT kernels seen on first inference before collecting latency numbers.
2. Add or tune GB10 W8A8 Block FP8 configs for the missing shapes before changing model architecture.
3. Run the recorded 136K and 186K long-context tests locally to compare against the May 27 `spark-2822` evidence.
4. For multi-rig speculative fill/load, do not count remote draft output as accepted until worker candidate token IDs and Spark verifier accept/reject plumbing are implemented and logged.
