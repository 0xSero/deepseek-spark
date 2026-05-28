---
license: mit
library_name: transformers
pipeline_tag: text-generation
tags:
  - deepseek-v4
  - mixture-of-experts
  - reap
  - dgx-spark
  - vllm
  - long-context
  - fp8
  - mxfp4
  - speculative-decoding
  - experimental
base_model: deepseek-ai/DeepSeek-V4-Flash
---

# DeepSeek-V4-Flash-Spark

**180B parameters | K160 REAP-pruned | 200K context | MTP speculative decoding**

This is a pruned and quantized DeepSeek V4 Flash that runs on a single DGX Spark. It is not the original model. It is a derivative built to fit into 128 GB of host memory while keeping the full 200,000-token context window alive.

The goal was simple: take one of the best open reasoning models available and make it runnable on a desktop AI workstation without losing what makes it useful. The result serves at about 24 tok/s decode with 2-token speculative decoding, and it retains a needle buried at 200K context.

## What this is

- Base: `deepseek-ai/DeepSeek-V4-Flash`
- Pruning: REAP (Routing-Enhanced Activation Pruning) at K160
- Final size: ~180B active parameters
- Quantization: NVFP4 / MXFP4 expert weights with FP8 KV cache
- Serving: vLLM with DeepSeek V4 tokenizer, reasoning parser, and tool-call parser
- Context: 200,000 tokens validated end-to-end
- Hardware target: single NVIDIA DGX Spark / GB10 / SM121

The K160 checkpoint was chosen because it was the best balance found during testing. Smaller checkpoints (K144, 162B) could also reach 200K, but K160 kept more model capacity while still fitting in memory. Larger checkpoints (200B, 213B) could not reach API readiness on one Spark under any tested configuration.

## How the REAP checkpoint was made

REAP (Router-weighted Expert Activation Pruning) is the Cerebras Research one-shot MoE compression method: https://github.com/CerebrasResearch/reap.

Short version: take DeepSeek V4 Flash, measure which MoE experts actually matter under real prompts, keep the most useful routed experts, delete the colder ones, remap the router/expert tables, then pack the surviving model into the low-bit format we serve.

Step by step:

**1. Start from DeepSeek V4 Flash.** DeepSeek V4 Flash is a sparse MoE model. Every token does not use every expert; the router picks a small top-k subset per token. That sparsity is what makes expert pruning viable. The served K160/K144 checkpoints keep this structure: `model_type=deepseek_v4`, 43 hidden layers, hidden size 4096, 1 shared expert, 6 routed experts active per token, and `max_position_embeddings=1048576` from the base.

**2. Run calibration prompts through the original model.** A calibration corpus is passed through the unpruned model. For each token and each MoE layer, REAP records the router scores, which experts the top-k selected, how strongly the router weighted them, and how large the expert activations were. The useful signal is roughly `router_probability * topk_selected * activation_strength * frequency`. This is the "router-weighted activation" part of the name.

**3. Rank experts per layer.** Each MoE layer gets its own ranking. Hot experts are ones the router actually depends on; cold experts are rarely picked or contribute little.

```python
for layer in moe_layers:
    scores = {}
    for batch in calibration_data:
        router_output = model.router(layer, batch.hidden_states)
        topk_experts, gate_weights = select_experts(router_output)
        for token in batch.tokens:
            for expert, weight in topk_experts[token]:
                activation = estimate_activation_strength(layer, expert, token)
                scores[expert] += weight * activation
    keep_experts[layer] = top_k(scores, K)
```

For this checkpoint, `K=160` routed experts per MoE layer are kept. The shared expert is always kept.

**4. Physically prune the expert weights.** This is structural surgery on the MoE expert tensors, not LoRA, prompt tuning, or fine-tuning. Embeddings, attention layers, norms, router, shared expert, selected routed experts, and the LM head all stay. Low-ranked routed experts are removed, and the expert IDs are remapped so the model has a compact expert table. That is why the config now reports `n_routed_experts: 160` instead of the larger original count.

**5. Update router metadata.** Because experts were deleted, the router cannot point at old expert IDs. REAP rewrites the routing metadata and the token-to-expert mapping used by the runtime. This is why vLLM needed a router patch: K160 and K144 are valid checkpoints but use nonstandard routed-expert counts that some fused CUDA router kernels do not template-instantiate. The patch forces the general fallback router path. It does not change weights or model behavior.

**6. Quantize and pack.** The pruned checkpoint is packed into the low-bit format the runtime serves: MXFP4/NVFP4-style packed expert weights with FP8 MLA KV cache. That is how K160 lands in a memory range that fits on one DGX Spark.

**7. Validate quality and fit.** Multiple sizes were tested on one Spark: 213B was too large, 200B failed readiness, 180B/K160 was the best balance, and 162B/K144 was the smaller fallback. K160 won because it preserved more capacity than K144 while still fitting at 200K context with MTP2 speculative decoding.

### What REAP changes vs. preserves

Changes: number of routed experts, expert tensors, expert ID mapping, checkpoint size, runtime memory footprint.

Preserves: context length, tokenizer, attention architecture, number of layers, hidden size, number of experts used per token, base chat format.

### What we did in this project

We did not recreate the REAP pipeline ourselves. We downloaded the already-created REAP checkpoints, inspected their configs and expert counts, patched vLLM to accept the nonstandard expert counts, built and validated the DGX Spark runtime, found working one-Spark profiles, and published the serving repos, configs, and model cards.

The end-to-end artifact:

```text
DeepSeek V4 Flash
  -> router-weighted expert pruning (REAP)
  -> K160 expert-retained checkpoint
  -> low-bit packed checkpoint
  -> vLLM Spark runtime
  -> 200K context serving recipe
```

## How we got here

This was not a straightforward port. DeepSeek V4 Flash is a 641B-parameter MoE model. The public vLLM recipe for 200K context assumes two DGX Sparks in tensor-parallel. We had one.

The path to a single-Spark 200K server involved:

1. **Building a native ARM64 vLLM image** from the DeepSeek V4 community branch (`vllm-project/vllm#41834`), since the published NVIDIA images were amd64-only.
2. **Patching the runtime** to handle REAP's nonstandard expert counts, MXFP4 memory layout, and a FlashInfer CUDA IPC fix.
3. **Applying the NVIDIA forum Cutlass 4.5.1 workaround** to fix a MoE kernel dispatch issue that blocked loading on GB10.
4. **Testing every checkpoint** from 148B through 213B. 148B, 200B, and 213B all failed before `/v1/models` on one Spark. K160 was the largest that survived.
5. **Tuning the memory profile** through dozens of iterations: KV cache size, prefill chunking, batch limits, CUDA graph capture, and watchdog thresholds.
6. **Validating the 200K needle** and a full qualitative task suite: smoke, diagrams, code, philosophy, tool calls, and long-context retrieval.

The full evidence is in the runtime repo. Every failure, every parameter change, and every benchmark result is documented there.

## One-command install

Run this on the DGX Spark. `HF_TOKEN` is only needed if the model repo is private or not already cached.

```bash
HF_TOKEN=... bash -lc 'set -euo pipefail; cd /home/sero/spark; rm -rf deepseek-spark; git clone https://github.com/0xSero/deepseek-spark.git; cd deepseek-spark; ./setup.sh full k160'
```

Do not commit tokens. Pass them only through the environment for this one command.

## Exact working profile

The profile lives at `configs/k160-mtp2-200k.env` in the GitHub repo.

```bash
MODEL_REPO=0xSero/DeepSeek-V4-Flash-180B
MODEL_REVISION=7c360e1cd4a5168099dbc54d16d929bf6df04990
SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
CONTEXT_LENGTH=200000
KV_CACHE_MEMORY_BYTES=6G
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=1
GPU_MEMORY_UTILIZATION=0.88
WATCHDOG_MIN_AVAILABLE_KB=6291456
KV_CACHE_DTYPE=fp8
THINKING=true
SPECULATIVE_CONFIG='{"method":"deepseek_mtp","num_speculative_tokens":2}'
VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=0
VLLM_TRITON_MLA_SPARSE_ALLOW_CUDAGRAPH=1
```

The launcher enables DeepSeek V4 tokenizer, reasoning parser, tool-call parser, prefix caching, FP8 KV, MTP speculative decoding, and CUDA graph capture.

## Docker runtime

No public prebuilt Docker image is currently published. The installer uses the local validated image if present; otherwise it builds the native DGX Spark image locally from public sources.

The image lineage is the DGX Spark DeepSeek V4 vLLM build `vllm-node-dsv4:latest` with vLLM `0.1.dev17016+g27fd665bd.d20260526` and `nvidia-cutlass-dsl[cu13]==4.5.1`. The final local tag is `vllm-node-dsv4-cutlass451:latest`.

Exact image validated on `spark-2822`:

```text
vllm-node-dsv4-cutlass451:latest
sha256:5df60ebb9c10dfb86d5946cae8244adfe65a7fd405401bd542ecf22d5c497a4a
```

If you have published your own registry image, pass it explicitly with `IMAGE_REF=...`. The default path does not depend on a private or missing registry package.

The runtime patcher applies the nonstandard REAP expert-count router fallback, MXFP4 memory hygiene, optional cute-dsl override hook, and a FlashInfer CUDA IPC `libcudart` fix. It does not modify model weights.

## Validation

Run on `spark-2822`, a single DGX Spark / GB10 / SM121, on May 27 2026.

Startup:

```text
MTP draft model loaded: 39 params
Model loading took 96.66 GiB memory
GPU KV cache size: 537,516 tokens
Maximum concurrency for 200,000 tokens per request: 2.69x
Graph capturing finished in about 20 seconds and used about 1.66 GiB
```

200K long-needle benchmark:

```text
run_dir: /home/sero/spark/benchmarks/deepseek-reap/single-server-sweep/k160-mtp2-200k-mnbt4096-kv6g-20260527T192208Z
prompt_tokens: 186,390
TTFT: 362.573 s
prefill: 514.075 tok/s
decode: 24.378 tok/s
needle_retained: true
watchdog_kill: false
```

200K long-coding benchmark:

```text
run_dir: /home/sero/spark/benchmarks/deepseek-reap/single-server-sweep/k160-mtp2-200k-longcoding-fixed-20260527T194241Z
prompt_tokens: 182,112
TTFT: 353.799 s
prefill: 514.733 tok/s
decode: 18.946 tok/s
mentions_off_by_one: true
watchdog_kill: false
```

Task coverage at 200K: smoke, ASCII, Unicode, and Mermaid diagrams; code explanation; religion and philosophy prompts; tool-call fidelity; long-needle retrieval; and long-code review. Smoke, diagrams, code, religion, tool calls, and needle retrieval all passed. A few qualitative rubrics missed narrow fields at 128 output tokens, so benchmark prompts should reserve more completion tokens when judging broad reasoning quality.

## Why K160 with MTP2

K160 with MTP2 was the best single-Spark balance found. It kept the 200K path alive without a watchdog kill and roughly doubled decode speed versus no-spec in comparable long-context tests. The 6 GB KV pool and 4096-token prefill chunks leave enough room for the weights, DeepGEMM and CUDA graph workspaces, and activations on a 121 GB usable-memory GB10 system.

## Limitations

- This is a pruned model. It is not the full DeepSeek V4 Flash. Evaluate quality against your own tasks before trusting it for production work.
- 200K context works, but it is tight. The server loads, serves, and tears down cleanly, but memory is near the ceiling. Do not expect high concurrency.
- The public 200K success path for the full model remains dual-Spark TP=2. This single-Spark profile is a compromise.
- The Docker image and patches are experimental. They are not upstream vLLM and may break on newer commits.

## Links

- One-command wrapper: https://github.com/0xSero/deepseek-spark
- Runtime module (configs, patcher, evidence): https://github.com/0xSero/deepseek-v4-flash-spark-200k
- Base model: https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash

## License

MIT for the serving recipe and tooling. The base model weights follow the DeepSeek V4 Flash license. Review it before use.
