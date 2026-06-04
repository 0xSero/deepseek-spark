# Failed Kernel Testing Package

Public handoff package for the DeepSeek-V4-Flash-Spark / 0xSero single-DGX-Spark research lane.

This package is intended for another agent to quickly understand what was tested, what worked, what failed, and what must not be repeated without a structural change. It preserves the research notes and local reproducibility surfaces without publishing secret local env files, tokens, model weights, or private security handoff notes.

This is a handoff/archive package, not a standalone runnable tree. The copied scripts preserve the original repository assumptions. To run them, use the live repository layout or map:

```text
artifacts/scripts/ -> runtime/scripts/
artifacts/configs/ -> runtime/configs/
artifacts/setup-scripts/ -> repo root scripts plus setup.sh
artifacts/recipes/ -> config/recipes/
```

## Contents

- `artifacts/evidence/` - run notes, benchmark summaries, negative kernel route record, recovery note, and context-eval JSON.
- `artifacts/configs/` - serving profiles used or prepared for K160/K144 comparisons.
- `artifacts/scripts/` - runtime launch, patch, smoke, context-eval, and split-spec helper scripts.
- `artifacts/setup-scripts/` - wrapper setup, recipe preload, healthcheck, and validation scripts.
- `artifacts/model-cards/` - public model-card drafts for the REAP-pruned K160/K144 checkpoints.
- `artifacts/runtime-docs/` - runtime README, exact working config, and split-spec foundation note.
- `artifacts/recipes/` - vLLM Studio recipe JSON for K160 and K144.
- `artifacts/root-docs/` - root README, package metadata, and the local baseline bench runner.

## Main Findings

- K160 MTP2 with 6 GB FP8 KV served the 180B REAP checkpoint at 200K context and retained the 200K needle.
- Stock DS0 K160 warm baseline is the control to beat: 30.2 tok/s median decode, 1685 ms TTFT, single stream, temperature 0, two warmups discarded, five timed reps.
- K144 no-spec can serve 200K context but had thin teardown memory margin in the recorded sweep.
- The Warpgate route 28 `bshared64x128_u32_swizzle` preserved exactness but did not beat the vLLM-original comparator.
- The next kernel/testing loop should reject small swizzle/tile/flag churn and require a named structural performance vector.

## Public Boundary

This package intentionally excludes:

- model weights and cache directories
- secret local env files and API keys
- private `HANDOFF.md`
- local helper files such as `spark-local.env`, `preflight.sh`, `wait_ready.sh`, `dl_via_install.sh`, and `offload_ds4.sh`
- raw Warpgate JSON for route 28, because the surviving recovery note says those raw files were not present after reboot

Historical evidence notes still mention local paths and commands used on `spark-2949`. Those mentions are provenance, not portable instructions by themselves.

## Read First

1. `RESEARCH_INDEX.md`
2. `PUBLIC_HANDOFF.md`
3. `PROVENANCE.md`
4. `KNOWN_GAPS.md`
5. `artifacts/evidence/2026-06-02-warpgate-perfvect-loop.md`
