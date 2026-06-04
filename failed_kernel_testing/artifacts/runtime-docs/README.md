# DeepSeek V4 Flash Spark Runtime

Reproducible recipe for serving the REAP-pruned DeepSeek V4 Flash models on one DGX Spark with vLLM, FP8 MLA KV, CUDA graphs, and optional DeepSeek MTP speculative decoding.

This is the runtime module of the [deepseek-spark](https://github.com/0xSero/deepseek-spark) wrapper. It contains the configs, GB10 patcher, launch scripts, model cards, and evidence.

Served API names:

- `DeepSeek-V4-Flash-Spark` -> https://huggingface.co/0xSero/DeepSeek-V4-Flash-180B
- `DeepSeek-V4-Flash-Spark-Mini` -> https://huggingface.co/0xSero/DeepSeek-V4-Flash-162B

The full Spark wrapper (one-command vLLM Studio install) lives at the parent repo:

```bash
HF_TOKEN=... bash -lc 'set -euo pipefail; cd <spark-root>; rm -rf deepseek-spark; git clone https://github.com/0xSero/deepseek-spark.git; cd deepseek-spark; ./setup.sh full k160'
```

## Standalone Use

To launch the model server directly without vLLM Studio, run from inside this directory:

```bash
HF_TOKEN=... ./install.sh --profile k160-mtp2-200k --launch
HF_TOKEN=... ./install.sh --profile k144-nospec-200k --launch
```

`HF_TOKEN` is only needed if the Hugging Face model is private or not already cached.

## Docker Image

The runtime Docker image is published at:

```text
ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27
```

The installer uses this order:

1. Use the local validated image `vllm-node-dsv4-cutlass451:latest` if it already exists.
2. Pull `ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27`.
3. If the image is unavailable, build from public sources as a fallback.

Validated local Docker image on `spark-2822`:

```text
vllm-node-dsv4-cutlass451:latest
sha256:5df60ebb9c10dfb86d5946cae8244adfe65a7fd405401bd542ecf22d5c497a4a
ghcr manifest digest: sha256:e4462a915ba56026f9c7b5ed195180e07986983ac1aa26a8bb0160d7a031f396
```

## Default Working Profile

`configs/k160-mtp2-200k.env`:

```bash
MODEL_REPO=0xSero/DeepSeek-V4-Flash-180B
MODEL_REVISION=7c360e1cd4a5168099dbc54d16d929bf6df04990
SERVED_MODEL_NAME=DeepSeek-V4-Flash-Spark
CONTEXT_LENGTH=200000
KV_CACHE_MEMORY_BYTES=6G
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=1
THINKING=true
SPECULATIVE_CONFIG='{"method":"deepseek_mtp","num_speculative_tokens":2}'
```

The launch script also enables FP8 KV, DeepSeek V4 tokenizer/tool/reasoning parsers, prefix caching, `FULL_AND_PIECEWISE` CUDA graphs, and the GB10 REAP patcher.

## Model Cards

Prepared cards:

- `model-cards/Deepseek-V4-Flash-162B-REAP.md`
- `model-cards/Deepseek-V4-Flash-180B-REAP.md`

Upload them after logging into Hugging Face with write access to the `0xSero` repos:

```bash
HF_TOKEN=... ./scripts/upload_model_cards.sh
```

On Spark, a safer form is:

```bash
PYTHON=<spark-root>/tools/hf-download-venv/bin/python HF_TOKEN_FILE=<hf-token-file> ./scripts/upload_model_cards.sh
```

The upload script writes only `README.md` in each model repo. It never prints the token.

## Evidence

Measured on `spark-2822`, May 27 2026:

| profile | ready | watchdog | prompt tokens | TTFT | prefill | decode | result |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| K160 MTP2, 6G KV, 4096 chunk | yes | no | 186,390 | 362.573s | 514.075 tok/s | 24.378 tok/s | 200K needle retained |
| K160 MTP2, fixed coding prompt | yes | no | 182,112 | 353.799s | 514.733 tok/s | 18.946 tok/s | off-by-one found |
| K144 no-spec, 14G KV, 8192 chunk | yes | teardown kill | 186,390 | 345.834s | 538.958 tok/s | 13.899 tok/s | 200K needle retained |
| K160 MTP2, 6G KV, 4096 chunk | yes | no | 136,534 | 248.217s | 550.059 tok/s | 33.287 tok/s | needle retained |
| K160 no-spec, 8G KV, 4096 chunk | yes | no | 136,534 | 246.729s | 553.376 tok/s | 13.188 tok/s | needle retained |
| K144 no-spec, 14G KV, 8192 chunk | yes | no | 136,534 | 234.304s | 582.721 tok/s | 12.531 tok/s | needle retained |

K144 MTP2 improved short decode but was not long-context safe at the tested 8G watchdog threshold. K144 no-spec 14G/8192 proves the 200K path but has very thin teardown margin. K160 MTP2 was made long-context safe by using a 6G KV pool.

## Notes

- The working profiles capture CUDA graphs.
- The image lineage is `vllm-node-dsv4:latest` / vLLM `0.1.dev17016+g27fd665bd.d20260526` plus `nvidia-cutlass-dsl[cu13]==4.5.1`.
- The patcher applies the REAP nonstandard expert-count router fallback, MXFP4 memory hygiene, optional cute-dsl override hook, and FlashInfer CUDA IPC libcudart fix.
- The default Docker image is `ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27`; set `IMAGE_REF` only to test a different runtime image.
- Never commit `.env` files or tokens. Pass `HF_TOKEN` and `GITHUB_TOKEN` through the environment only.

## Split Spec Decode Foundation

The first split-serving scaffold is in
[`split-spec-decode-foundation.md`](split-spec-decode-foundation.md). It keeps
Spark as the canonical long-context prefill/verifier and lets an RTX 3090 or RTX
4080 host act as a measured draft/decode worker selected by
`scripts/split_spec_probe.py`.
