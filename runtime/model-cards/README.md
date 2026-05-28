# Model Cards

Hugging Face model card READMEs for the validated DGX Spark DeepSeek V4 Flash profiles.

| Model | HF Repo | Served Name | Params | Context | Speculative | Best For |
|---|---|---|---|---|---|---|
| [DeepSeek-V4-Flash-Spark](Deepseek-V4-Flash-180B-REAP.md) | [0xSero/DeepSeek-V4-Flash-180B](https://huggingface.co/0xSero/DeepSeek-V4-Flash-180B) | `DeepSeek-V4-Flash-Spark` | 180B | 200K | MTP2 | Best balance of capacity and speed on one Spark |
| [DeepSeek-V4-Flash-Spark-Mini](Deepseek-V4-Flash-162B-REAP.md) | [0xSero/DeepSeek-V4-Flash-162B](https://huggingface.co/0xSero/DeepSeek-V4-Flash-162B) | `DeepSeek-V4-Flash-Spark-Mini` | 162B | 200K | None | Higher prefill speed, more conservative memory |

Both are REAP-pruned derivatives of `deepseek-ai/DeepSeek-V4-Flash` built to run on a single DGX Spark / GB10 / SM121. They are experimental. Evaluate quality on your own tasks before production use.

The full story of how these were built lives in the model cards above and the [deepseek-spark](https://github.com/0xSero/deepseek-spark) repo. The cards document the local Docker build path instead of depending on a missing registry image.
