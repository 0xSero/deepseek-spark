# Power Outage Recovery Note

Date: 2026-06-02
Working dir: `/home/frosty40/ds0`

## Host Interruption

Observed boot history:

- Previous boot ended: `2026-06-02 05:22:01 CDT`
- Current boot began: `2026-06-02 09:18:02 CDT`
- `tmux ls` after reboot: no tmux socket present
- Active GPU compute after reboot: none observed by `nvidia-smi`
- Active DeepSeek/Warpgate/vLLM containers after reboot: none observed by `docker ps`

This means the 24H+ research loop did not survive the outage as a running
process.

## Surviving Research Artifact

The newest surviving Warpgate research note is:

- `runtime/evidence/2026-06-01-warpgate-bshared64x128-u32-swizzle-negative.md`

It records route `28`, `warpgate_mxf8_bshared64x128_u32_swizzle`, under:

- shape: `M=128,N=8192,K=4096`
- context tokens: `65000`
- output dtype: `float16`
- comparator: local vLLM-original `_w8a8_triton_block_scaled_mm`
- tolerance: `0.0`

Recorded result:

- smoke rep3: Warpgate `0.21580799420674643 ms`, vLLM-original
  `0.2136746644973755 ms`, speedup `0.9901146863571366`, max error `0.0`
- rep8: Warpgate `0.21518799662590027 ms`, vLLM-original
  `0.2088800072669983 ms`, speedup `0.9706861467283964`, max error `0.0`

Boundary from the note: exactness was preserved, but the route did not beat the
vLLM-original comparator.

## Missing Raw Artifact Gap

The June 1 note references raw JSON files under:

- `runtime/evidence/warpgate-bshared64x128-u32-swizzle-direct/`

That directory was not present in `/home/frosty40/ds0` after reboot. Targeted
checks in `/home/frosty40/ds0`, `/home/frosty40/ds0-pr-clean`, and
`/home/frosty40/spark` found only the markdown note, not the referenced JSON.

Treat the markdown as the surviving result record, but do not claim raw JSON
artifact availability unless those files are recovered from another location.

## Resume Boundary

Do not continue small shared-B indexing variants as the default path from this
interrupted loop. The surviving result says the next route should isolate the
vLLM generated dataflow more directly:

- `64x128x128`
- four warps
- no split-K atomics
- FP32 accumulator lifetime per tile
- operand movement structured closer to Triton `tl.load` plus `tl.dot`

Before resuming a long loop, create an output directory that is committed or
checkpointed after each completed route so raw JSON cannot be lost separately
from the markdown summary.
