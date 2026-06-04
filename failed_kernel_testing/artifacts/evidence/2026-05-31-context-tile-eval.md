# 2026-05-31 Context And Tile Performance Eval

Working directory: `/home/frosty40/ds0`
Model: `DeepSeek-V4-Flash-Spark`
Profile: `k160-mtp2-200k`
Server: `http://127.0.0.1:18000`
Run type: controlled local context retrieval and runtime performance inspection

## Condition

Same serving condition as `runtime/configs/k160-mtp2-200k.env`:

```text
MODEL_REPO=0xSero/DeepSeek-V4-Flash-180B
MODEL_REVISION=7c360e1cd4a5168099dbc54d16d929bf6df04990
CONTEXT_LENGTH=200000
KV_CACHE_MEMORY_BYTES=6G
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=1
KV_CACHE_DTYPE=fp8
THINKING=true
SPECULATIVE_CONFIG={"method":"deepseek_mtp","num_speculative_tokens":2}
```

The context runner does not import model/tokenizer code into the serving
container. It records server-reported `usage.prompt_tokens` from the OpenAI
response.

Runner:

```text
runtime/scripts/context_eval.py
```

## Results

| target prompt tokens | observed prompt tokens | result | elapsed s | artifact |
| ---: | ---: | --- | ---: | --- |
| 8,192 | 8,232 | pass | 13.216 | `runtime/evidence/context-evals/20260531T-context-ladder-k160/needle-8192.json` |
| 32,768 | 32,568 | pass | 47.152 | `runtime/evidence/context-evals/20260531T-context-ladder-k160/needle-32768.json` |
| 65,536 | 65,014 | pass | 101.564 | `runtime/evidence/context-evals/20260531T-context-65k-k160-resume/needle-65536.json` |
| 136,000 | 134,854 | pass | 250.961 | `runtime/evidence/context-evals/20260531T-context-136k-k160-fresh/needle-136000.json` |
| 186,000 | 184,391 | pass | 380.105 | `runtime/evidence/context-evals/20260531T-context-186k-k160-fresh/needle-186000.json` |

All passing runs returned the exact inserted secret:

```text
SPARK-NEEDLE-<target>-73F9
```

## Important Failed Diagnostic

A tokenizer probe inside the live serving container was attempted and was
invalid for benchmarking. It loaded extra Python/model-side dependencies into a
tight memory condition and the watchdog killed the container:

```text
WATCHDOG_KILL 2026-05-31T14:03:07-05:00 mem_available_kb=6145052
```

That event is not model quality evidence. It is evidence that auxiliary tooling
must not run inside the memory-constrained serving container.

## 136K Retry Note

The first 136K attempt after accumulated prior traffic was killed by the
watchdog:

```text
WATCHDOG_KILL 2026-05-31T14:24:23-05:00 mem_available_kb=6266048
```

The same 136K context condition passed from a fresh K160 server. Treat the
watchdog kill as memory-margin/cached-state instability, not as a retrieval
failure.

## Tile / Kernel Findings

TileLang is active in the serving path. Logs showed compilation of:

```text
mhc_pre_big_fuse_with_norm_tilelang
mhc_post_tilelang
hc_head_fuse_tilelang
mhc_fused_tilelang
```

GB10 W8A8 FP8 configs present in the runtime image:

```text
N=1536,K=4096
N=16384,K=1024
N=2048,K=4096
N=4096,K=1024
N=4096,K=4096
N=8192,K=1024
```

GB10 W8A8 FP8 configs missing and falling back to defaults:

```text
N=32768,K=1024
N=4096,K=8192
N=4096,K=2048
```

The runtime also still reports first-request JIT compilation for several
prefill metadata, FP8, paged-attention, and MTP rejection kernels. This causes
cold-request latency spikes and should be handled with an explicit warmup shape
pass before collecting latency numbers intended to represent steady state.

## Performance Read

Observed prompt-throughput including decode and HTTP wall time:

```text
8K:   622.9 prompt tok/s
32K:  690.7 prompt tok/s
65K:  640.1 prompt tok/s
136K: 537.3 prompt tok/s
186K: 485.1 prompt tok/s
```

The 136K and 186K numbers are consistent with the prior May 27 long-context
evidence class, but are not identical benchmarks: this runner uses a synthetic
needle prompt and reports end-to-end HTTP wall time.

## Next Work

1. Add a no-competing-traffic guard to the context runner by checking
   `vllm:num_requests_running` and `vllm:num_requests_waiting` before launch.
2. Add a warmup pass that covers the first-request JIT kernels before measuring
   steady-state latency.
3. Use NVIDIA/TileLang tooling to tune or add GB10 W8A8 configs for the missing
   shapes before changing model or speculative decode policy.
4. Keep long-context evals one-at-a-time; 136K+ is close enough to the watchdog
   floor that accumulated cache state can change run stability.
