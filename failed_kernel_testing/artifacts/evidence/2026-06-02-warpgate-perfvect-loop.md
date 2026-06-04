# Warpgate PerfVect Loop

Date: 2026-06-02
Scope: W8A8 FP8 native Warpgate routes after route `28`

## Purpose

This loop is meant to keep the agent out of boring knob-tweak territory. A new
route is only allowed if it changes a named performance vector in the actual
dataflow. Shared-memory indexing variations, tile-size churn, warmup/rep churn,
and compiler-flag churn are not enough.

## Fixed Comparator

Keep this condition fixed unless a separate evidence note explicitly changes
the benchmark target:

- shape: `M=128,N=8192,K=4096`
- context tokens: `65000`
- output dtype: `float16`
- comparator: local vLLM-original `_w8a8_triton_block_scaled_mm`
- correctness tolerance: `0.0`
- minimum accepted result: exact output and faster than vLLM-original on rep8

## Performance Vectors

Every route proposal must choose exactly one primary vector and one secondary
vector from this list:

- `operand_pipeline`: make A/B movement closer to Triton `tl.load` plus
  `tl.dot`; reduce scalar unpack plumbing.
- `accumulator_lifetime`: keep FP32 accumulators live per tile with fewer
  round trips, barriers, or staging hazards.
- `warp_work_partition`: change which warp owns which N/K lane and how work is
  synchronized.
- `mma_feed_shape`: change how packed FP8 values are presented to the dot path,
  not just where they sit in shared memory.
- `scale_application`: move or batch scale use so it is aligned with the dot
  pipeline instead of a side-band cost.
- `generated_dataflow_match`: reproduce one concrete behavior observed from
  vLLM/Triton generated code.

Rejected vectors:

- `shared_index_swizzle_only`
- `tile_size_only`
- `rep_count_only`
- `compiler_flag_only`
- `minor_barrier_shuffle`
- `same_route_with_rename`

## Route Admission Gate

Before writing code, fill this out. If any line is vague, stop.

```text
route_id:
primary_vector:
secondary_vector:
specific vLLM/Triton behavior being matched:
current Warpgate behavior being removed:
expected bottleneck changed:
why this is not a knob tweak:
correctness invariant:
benchmark command:
artifact path:
```

Admission rule:

- The route must delete or replace at least one structural behavior from route
  `27`/`28`.
- The proposal must name a data-movement, accumulator, warp-partition, or
  generated-dataflow behavior.
- If the only explanation is "try a different swizzle", "try another tile", or
  "maybe this schedules better", reject it.

## Loop

1. Inspect one concrete vLLM/Triton generated path for the fixed comparator.
   Record the observed load, dot, scale, accumulator, and warp behavior in the
   route note before coding.

2. Write the admission block. Do not touch code until the block names the
   primary and secondary performance vectors.

3. Implement the smallest route that changes that vector. Avoid adding fallback
   complexity unless it is required to compile or preserve exactness.

4. Run a smoke test:

```bash
PYTHONDONTWRITEBYTECODE=1 \
python3 runtime/scripts/smoke_w8a8_fp8_mxf8_direct_fp8_utils.py \
  --label ROUTE_LABEL-smoke \
  --shape 128,8192,4096 \
  --context-tokens 65000 \
  --output-dtype float16 \
  --warmup 1 \
  --rep 3 \
  --expect-native-route \
  --enable-native-experimental \
  --compare-vllm-original \
  --vllm-original-tolerance 0.0 \
  --min-speedup-vs-vllm-original 0.0 \
  --output-dir runtime/evidence/ROUTE_LABEL
```

5. If smoke is inexact, stop that route. Do not tune speed on an inexact route.
   Record the failed invariant.

6. If smoke is exact, run rep8:

```bash
PYTHONDONTWRITEBYTECODE=1 \
python3 runtime/scripts/smoke_w8a8_fp8_mxf8_direct_fp8_utils.py \
  --label ROUTE_LABEL-rep8 \
  --shape 128,8192,4096 \
  --context-tokens 65000 \
  --output-dtype float16 \
  --warmup 3 \
  --rep 8 \
  --expect-native-route \
  --enable-native-experimental \
  --compare-vllm-original \
  --vllm-original-tolerance 0.0 \
  --min-speedup-vs-vllm-original 0.0 \
  --output-dir runtime/evidence/ROUTE_LABEL
```

7. Immediately write a markdown result note and keep the raw JSON in the same
   route output directory. The note must include:

- route id and vector block
- exact command
- raw JSON path
- Warpgate ms
- vLLM-original ms
- speedup
- max error
- keep/kill decision

8. Decision:

- `keep`: exact and rep8 speedup is greater than `1.0`.
- `kill`: exact but speedup is less than or equal to `1.0`.
- `invalid`: inexact, route mismatch, missing comparator, or missing raw JSON.

9. After two consecutive `kill` results in the same primary vector, stop that
   vector. Move to a different primary vector or inspect more generated code.

## First Allowed Next Route

The next route should not be another shared-B index variant. A valid next route
is:

```text
route_id: 29
primary_vector: generated_dataflow_match
secondary_vector: operand_pipeline
specific vLLM/Triton behavior being matched: one inspected tl.load plus tl.dot
  operand feed pattern for M=128,N=8192,K=4096
current Warpgate behavior being removed: hand-coded scalar unpack/staging path
  that does not match the generated dot feed
expected bottleneck changed: operand movement into the dot path
why this is not a knob tweak: it changes the representation and movement of
  operands, not just a shared-memory index or tile constant
correctness invariant: max error 0.0 against vLLM-original
benchmark command: fixed comparator smoke then rep8
artifact path: runtime/evidence/warpgate-route29-generated-dataflow-match
```

If route `29` cannot name the inspected generated-code behavior, do not start
coding it.
