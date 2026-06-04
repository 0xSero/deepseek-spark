# Public Handoff

## Objective

Package the DeepSeek-V4-Flash-Spark research lane so another agent can reproduce the serving setup, understand the benchmark/control condition, and avoid repeating failed kernel-search paths.

## What Worked

- The K160 180B REAP checkpoint served on one DGX Spark / GB10 with vLLM.
- The intended K160 profile used 200K context, 6 GB FP8 KV cache, max batch tokens 4096, max seqs 1, and MTP2 speculative decoding.
- 200K needle retrieval passed in the recorded sweeps.
- A stable stock warm baseline was recorded at 30.2 tok/s median decode.

## What Failed Or Was Invalid

- K144 no-spec could serve 200K but had thin memory margin around teardown.
- A live-container tokenizer probe was invalid as a benchmark method because it added memory pressure and triggered the watchdog.
- The route 28 Warpgate shared-B u32 swizzle preserved exactness but was slower than the vLLM-original comparator.
- The raw JSON files for route 28 were missing after a reboot; do not claim raw JSON availability from this package.
- The prior no-watchdog/heavier manual launch path caused an OOM incident; future control runs should keep the intended 6 GB watchdog floor.

## Agent Guidance

Do not resume by trying another small shared-memory swizzle, tile churn, warmup-count tweak, or compiler-flag tweak. Future kernel work must pass the route admission gate in `artifacts/evidence/2026-06-02-warpgate-perfvect-loop.md` and name the structural dataflow behavior being changed.

For serving reproduction, prefer the direct runtime scripts and configs in:

```text
artifacts/configs/k160-mtp2-200k.env
artifacts/scripts/serve_profile.sh
artifacts/scripts/launch_vllm_deepseek_v4_guarded.sh
artifacts/scripts/patch_vllm_reap_gb10.py
```

These are archived copies. They assume the original repository layout. If an agent wants to execute them from this package, first restore the path mapping described in `README.md` or run the corresponding files from the repository root.

For benchmark/control comparison, start from:

```text
artifacts/evidence/2026-06-02-ds0-intended-warm-baseline.md
artifacts/root-docs/baseline_bench.py
```

## Public-Release Notes

This package does not include secret local env files, API keys, model weights, or the private handoff note. It does include non-secret `.env` serving profile files under `artifacts/configs/`. Some historical evidence notes refer to `spark-local.env` or absolute local paths; those are provenance references from the original environment, not files included for publication.
