# Exact Working Config

Use the public wrapper repo:

```bash
HF_TOKEN=... bash -lc 'set -euo pipefail; cd <spark-root>; rm -rf deepseek-spark; git clone https://github.com/0xSero/deepseek-spark.git; cd deepseek-spark; ./setup.sh full k160'
```

Default endpoints:

- UI: `http://<spark-tailnet-ip>:3000`
- Controller: `http://<spark-tailnet-ip>:8080`
- Model API: `http://<spark-tailnet-ip>:8000`

Docker image:

```text
ghcr.io/0xsero/deepseek-v4-flash-spark-vllm:cutlass451-g27
manifest digest: sha256:e4462a915ba56026f9c7b5ed195180e07986983ac1aa26a8bb0160d7a031f396
```

vLLM Studio source:

```text
https://github.com/sybil-solutions/vllm-studio.git#main
```

Models:

- `DeepSeek-V4-Flash-Spark`: `0xSero/DeepSeek-V4-Flash-180B`
- `DeepSeek-V4-Flash-Spark-Mini`: `0xSero/DeepSeek-V4-Flash-162B`
- 213B reference: https://huggingface.co/0xSero/DeepSeek-V4-Flash-213B/

K160 default:

```text
profile=k160-mtp2-200k
served_model_name=DeepSeek-V4-Flash-Spark
max_model_len=200000
kv_cache_dtype=fp8
kv_cache_memory_bytes=6G
max_num_batched_tokens=4096
max_num_seqs=1
gpu_memory_utilization=0.88
thinking=true
speculative_config={"method":"deepseek_mtp","num_speculative_tokens":2}
cuda_graphs=FULL_AND_PIECEWISE
```

K144 default:

```text
profile=k144-nospec-200k
served_model_name=DeepSeek-V4-Flash-Spark-Mini
max_model_len=200000
kv_cache_dtype=fp8
kv_cache_memory_bytes=14G
max_num_batched_tokens=8192
max_num_seqs=1
gpu_memory_utilization=0.88
thinking=true
speculative_config=
cuda_graphs=FULL_AND_PIECEWISE
```
