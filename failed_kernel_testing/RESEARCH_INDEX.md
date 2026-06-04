# Research Index

## Serving And Fit Evidence

- `artifacts/evidence/2026-05-27-k160-mtp2-200k.md`
  - K160 MTP2 200K evidence.
  - Reports ready server, no watchdog kill, long-needle pass, 96.66 GiB model memory, 537,516-token KV cache, and 200K max-concurrency estimate of 2.69x.
- `artifacts/evidence/2026-05-27-k144-k160-context-sweeps.md`
  - K144 no-spec and K160 MTP2 context sweeps.
  - K144 shows 200K viability with low teardown margin; K160 gives safer MTP2 profile.
- `artifacts/evidence/2026-05-31-local-k160-baseline.md`
  - Local K160 baseline on `spark-2949`.
  - Includes preflight, healthcheck, direct smoke, controller smoke, and split-spec probe.
- `artifacts/evidence/2026-05-31-context-tile-eval.md`
  - Controlled local context retrieval ladder from 8K through 186K target prompt tokens.
  - Includes important invalid diagnostic boundary: tokenizer probing inside the live serving container caused watchdog pressure and is not quality evidence.
- `artifacts/evidence/2026-06-02-ds0-intended-warm-baseline.md`
  - Control baseline after avoiding the prior OOM-causing launch path.
  - Score to beat: 30.2 tok/s median decode under the warm single-stream protocol.

## Kernel And Warpgate Evidence

- `artifacts/evidence/2026-06-01-warpgate-bshared64x128-u32-swizzle-negative.md`
  - Negative route record for route 28 under fixed W8A8 FP8 direct comparator.
  - Exactness held with max error 0.0, but speedup was below vLLM-original.
- `artifacts/evidence/2026-06-02-power-outage-recovery.md`
  - Recovery boundary after host interruption.
  - Records that route 28 raw JSON files were missing and only the markdown note survived.
- `artifacts/evidence/2026-06-02-warpgate-perfvect-loop.md`
  - Route admission gate for future kernel work.
  - Rejects shared-index-swizzle-only, tile-size-only, rep-count-only, compiler-flag-only, minor-barrier-shuffle, and same-route-with-rename work.

## Context Eval JSON

The JSON files under `artifacts/evidence/context-evals/` are the machine-readable records for the context retrieval ladder. They should be treated as raw output records for the corresponding May 31 context eval note.

## Runtime And Reproduction Surfaces

- `artifacts/configs/` contains the serving profiles.
- `artifacts/scripts/launch_vllm_deepseek_v4_guarded.sh` and `artifacts/scripts/serve_profile.sh` show the direct vLLM launch mechanics.
- `artifacts/scripts/patch_vllm_reap_gb10.py` records the GB10/REAP vLLM runtime patch surface.
- `artifacts/setup-scripts/` contains the wrapper setup and vLLM Studio path.
- `artifacts/model-cards/` contains public-facing model-card drafts for K160/K144.

## Current Live Smoke From Packaging Session

During package creation, the K160 API was relaunched on `spark-2949`:

```text
local endpoint: http://127.0.0.1:18000/v1
served model: DeepSeek-V4-Flash-Spark
Apollo tunnel: apollo 127.0.0.1:18000 -> spark-2949 127.0.0.1:18000
chat smoke content: DEEPSEEK_APOLLO_READY
```

This smoke confirms current serving availability for the handoff, but it is not a replacement for the historical benchmark artifacts.
