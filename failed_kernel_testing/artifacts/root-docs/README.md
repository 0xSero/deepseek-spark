# deepseek-spark

Barebones 1x DGX Spark launcher for [vLLM Studio](https://github.com/sybil-solutions/vllm-studio) plus the validated DeepSeek V4 Flash 200K recipes.

The DeepSeek V4 Flash Spark runtime (configs, patcher, evidence, launch scripts) lives in [`runtime/`](runtime/). The controller/frontend comes from [vLLM Studio](https://github.com/sybil-solutions/vllm-studio).

Hugging Face models:

- 180B / K160: https://huggingface.co/0xSero/DeepSeek-V4-Flash-180B
- 162B / K144: https://huggingface.co/0xSero/DeepSeek-V4-Flash-162B

## One Command

Run on the DGX Spark. `HF_TOKEN` is only needed when the Hugging Face repos are private or not cached.

```bash
HF_TOKEN=... bash -lc 'set -euo pipefail; cd <spark-root>; rm -rf deepseek-spark; git clone https://github.com/0xSero/deepseek-spark.git; cd deepseek-spark; ./setup.sh full k160'
```

The runtime Docker image is published at:

```text
ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27
```

`setup.sh` pulls that image automatically. It also fetches the remote `main`
branch of `sybil-solutions/vllm-studio` on every controller/API/full setup.

Default URLs are controlled by `TAILSCALE_HOST`, `CONTROLLER_PORT`, `INFERENCE_PORT`, and `FRONTEND_PORT`.

## Modes

```bash
./setup.sh model k160       # model API only
./setup.sh controller       # vLLM Studio controller + preloaded recipes
./setup.sh api k160         # controller + DeepSeek-V4-Flash-Spark launched through Studio
./setup.sh api k144         # controller + DeepSeek-V4-Flash-Spark-Mini launched through Studio
./setup.sh frontend         # optional frontend only
./setup.sh full k160        # api mode plus frontend
./setup.sh pi-models        # merge Spark models into ~/.pi/agent/models.json
./setup.sh status
./setup.sh stop
```

Use alternate ports without editing files:

```bash
CONTROLLER_PORT=18080 INFERENCE_PORT=18000 FRONTEND_PORT=13000 ./setup.sh full k160
```

## Preloaded Recipes

- `DeepSeek-V4-Flash-Spark` -> `0xSero/DeepSeek-V4-Flash-180B`
- `DeepSeek-V4-Flash-Spark-Mini` -> `0xSero/DeepSeek-V4-Flash-162B`

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

## Split Spec Decode Foundation

The RTX 3090/4080 draft-worker foundation is documented in
[`runtime/split-spec-decode-foundation.md`](runtime/split-spec-decode-foundation.md).
It keeps DGX Spark as the canonical long-context prefill/verifier and probes
remote RTX workers before selecting the decode side.

## Pi Agent Config

vLLM Studio's own agent runtime uses its app-local `studio-data/frontend/pi-agent` directory. It should not be pointed at the user's global `~/.pi/agent`.

For users who already have `~/.pi`, `setup.sh controller`, `setup.sh api`, and `setup.sh full` also merge a `deepseek-spark` provider into `~/.pi/agent/models.json`. Existing providers and API keys are preserved, a timestamped backup is written before changes, and the file is kept at `0600`.

Use these controls when needed:

```bash
UPDATE_PI_MODELS=0 ./setup.sh full k160      # skip global Pi config
UPDATE_PI_MODELS=1 ./setup.sh pi-models      # create/update ~/.pi even if it is missing
PI_MODELS_PROVIDER_ID=my-spark ./setup.sh pi-models
```

## Validation

After launch:

```bash
source runtime/studio.env
EXPECTED_MODEL=DeepSeek-V4-Flash-Spark \
CONTROLLER_URL=http://SPARK_TAILNET_IP:8080 \
INFERENCE_URL=http://SPARK_TAILNET_IP:8000 \
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
- Runtime details: [`runtime/README.md`](runtime/README.md)
- 180B model: https://huggingface.co/0xSero/DeepSeek-V4-Flash-180B
- 162B model: https://huggingface.co/0xSero/DeepSeek-V4-Flash-162B
