# Warpgate W8A8 FP8 B-Shared64x128 U32 Swizzle Negative

Date: 2026-06-01

## Boundary

This records route `28`, `warpgate_mxf8_bshared64x128_u32_swizzle`, under the
same controlled W8A8 FP8 direct comparator condition used for the current
Warpgate native route work.

Condition:

- shape: `M=128,N=8192,K=4096`
- context tokens: `65000`
- output dtype: `float16`
- comparator: local vLLM-original `_w8a8_triton_block_scaled_mm`
- tolerance against vLLM-original: `0.0`
- route flag: `--enable-bshared64x128-u32-swizzle`

## Implementation

Route `28` keeps the route `27` shape and scale-hoist structure:

- tile: `64x128x128`
- shared B tile packed as `uint32_t`
- direct packed A loads
- B scale hoisted once per `N128,K128` tile
- final post-compute shared-memory barrier skipped on the final K tile

The tested change is shared-B indexing swizzle:

```cpp
nn * 32 + (kk4 ^ (nn & 7))
```

## Commands

Smoke:

```bash
SPARK_WARPGATE_W8A8_FP8_NATIVE_EXT_NAME=warpgate_w8a8_fp8_native_ext_bshared64x128_u32_swizzle_smoke \
SPARK_WARPGATE_W8A8_FP8_NATIVE_BUILD_DIR=/tmp/warpgate-w8a8-fp8-native-build-bshared64x128-u32-swizzle-smoke \
PYTHONDONTWRITEBYTECODE=1 \
python3 runtime/scripts/smoke_w8a8_fp8_mxf8_direct_fp8_utils.py \
  --label warpgate-bshared64x128-u32-swizzle-direct-fp8-utils-fp16-m128-n8192-k4096-smoke \
  --shape 128,8192,4096 \
  --context-tokens 65000 \
  --output-dtype float16 \
  --warmup 1 \
  --rep 3 \
  --expect-native-route \
  --enable-native-experimental \
  --enable-bshared64x128-u32-swizzle \
  --compare-vllm-original \
  --vllm-original-tolerance 0.0 \
  --min-speedup-vs-vllm-original 0.0 \
  --output-dir runtime/evidence/warpgate-bshared64x128-u32-swizzle-direct
```

Rep8:

```bash
SPARK_WARPGATE_W8A8_FP8_NATIVE_EXT_NAME=warpgate_w8a8_fp8_native_ext_bshared64x128_u32_swizzle_smoke \
SPARK_WARPGATE_W8A8_FP8_NATIVE_BUILD_DIR=/tmp/warpgate-w8a8-fp8-native-build-bshared64x128-u32-swizzle-smoke \
PYTHONDONTWRITEBYTECODE=1 \
python3 runtime/scripts/smoke_w8a8_fp8_mxf8_direct_fp8_utils.py \
  --label warpgate-bshared64x128-u32-swizzle-direct-fp8-utils-fp16-m128-n8192-k4096-rep8 \
  --shape 128,8192,4096 \
  --context-tokens 65000 \
  --output-dtype float16 \
  --warmup 3 \
  --rep 8 \
  --expect-native-route \
  --enable-native-experimental \
  --enable-bshared64x128-u32-swizzle \
  --compare-vllm-original \
  --vllm-original-tolerance 0.0 \
  --min-speedup-vs-vllm-original 0.0 \
  --output-dir runtime/evidence/warpgate-bshared64x128-u32-swizzle-direct
```

## Evidence

- `runtime/evidence/warpgate-bshared64x128-u32-swizzle-direct/warpgate-bshared64x128-u32-swizzle-direct-fp8-utils-fp16-m128-n8192-k4096-smoke.json`
- `runtime/evidence/warpgate-bshared64x128-u32-swizzle-direct/warpgate-bshared64x128-u32-swizzle-direct-fp8-utils-fp16-m128-n8192-k4096-rep8.json`

## Results

| Run | Warpgate direct ms | vLLM-original ms | Speedup vs vLLM-original | Max error |
| --- | ---: | ---: | ---: | ---: |
| smoke rep3 | `0.21580799420674643` | `0.2136746644973755` | `0.9901146863571366` | `0.0` |
| rep8 | `0.21518799662590027` | `0.2088800072669983` | `0.9706861467283964` | `0.0` |

## Finding

The swizzle preserves exactness but does not beat vLLM-original. It is slightly
faster than route `27` in absolute Warpgate time on this rep8 artifact, but
vLLM-original also measured faster in the same run, so this is not a win.

The result argues against spending more time on small shared-B indexing variants
as the primary path. The next route should isolate vLLM's generated dataflow
more directly: `64x128x128`, four warps, no split-K atomics, FP32 accumulator
lifetime per tile, and operand movement structured to match Triton's `tl.load`
plus `tl.dot` pipeline rather than hand-coded scalar plumbing.
