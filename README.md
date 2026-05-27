# deepseek-spark

Barebones 1x DGX Spark launcher for [vLLM Studio](https://github.com/sybil-solutions/vllm-studio) plus the validated DeepSeek V4 Flash 200K recipes.

It stands beside two upstream pieces:

- Model/runtime module: https://github.com/0xSero/deepseek-v4-flash-spark-200k
- Controller/frontend: https://github.com/sybil-solutions/vllm-studio

## One Command

Run on the DGX Spark. `HF_TOKEN` is only needed when the Hugging Face repos are private or not cached.

```bash
HF_TOKEN=... bash -lc 'set -euo pipefail; cd /home/sero/spark; rm -rf deepseek-spark; git clone https://github.com/0xSero/deepseek-spark.git; cd deepseek-spark; ./setup.sh full k160'
```

Default URLs:

- UI: `http://100.83.190.2:3000`
- Controller: `http://100.83.190.2:8080`
- Model API: `http://100.83.190.2:8000`

## Modes

```bash
./setup.sh model k160       # model API only
./setup.sh controller       # vLLM Studio controller + preloaded recipes
./setup.sh api k160         # controller + DeepSeek-V4-Flash-Spark launched through Studio
./setup.sh api k144         # controller + DeepSeek-V4-Flash-Spark-Mini launched through Studio
./setup.sh frontend         # optional frontend only
./setup.sh full k160        # api mode plus frontend
./setup.sh status
./setup.sh stop
```

Use alternate ports without editing files:

```bash
CONTROLLER_PORT=18080 INFERENCE_PORT=18000 FRONTEND_PORT=13000 ./setup.sh full k160
```

## Preloaded Recipes

- `DeepSeek-V4-Flash-Spark` -> `0xSero/DeepSeek-V4-Flash-180B-codex-K160-REAP`
- `DeepSeek-V4-Flash-Spark-Mini` -> `0xSero/DeepSeek-V4-Flash-162B-codex-K144-REAP`

Both recipes use:

- 200,000 token context
- FP8 MLA KV
- DeepSeek V4 tokenizer, tool-call parser, and reasoning parser
- thinking enabled through `--default-chat-template-kwargs '{"thinking":true}'`
- CUDA graphs enabled
- predictable Docker container names so Studio logs can tail the running server

K160 additionally enables MTP speculative decoding:

```text
SPECULATIVE_CONFIG={"method":"deepseek_mtp","num_speculative_tokens":2}
```

## Validation

After launch:

```bash
source runtime/studio.env
EXPECTED_MODEL=DeepSeek-V4-Flash-Spark \
CONTROLLER_URL=http://100.83.190.2:8080 \
INFERENCE_URL=http://100.83.190.2:8000 \
./scripts/healthcheck.sh
```

The healthcheck verifies:

- model name in `/v1/models`
- exact Docker launch flags for thinking, tools, reasoning, and container naming
- direct and controller streaming
- Studio logs
- Studio metrics
- `/benchmark` SQLite write path

## Security

`setup.sh` writes a random controller API key to `runtime/studio.env` and a matching frontend proxy settings file under `studio-data/frontend/`. Both paths are ignored by git. Do not commit Hugging Face, GitHub, or controller tokens.

## Links

- vLLM Studio: https://github.com/sybil-solutions/vllm-studio
- Working Docker/model module: https://github.com/0xSero/deepseek-v4-flash-spark-200k
- 162B model: https://hf.co/0xSero/DeepSeek-V4-Flash-162B-codex-K144-REAP
- 180B model: https://hf.co/0xSero/DeepSeek-V4-Flash-180B-codex-K160-REAP
- 213B model: https://huggingface.co/0xSero/DeepSeek-V4-Flash-213B/
