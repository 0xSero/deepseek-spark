# Split Spec Decode Foundation

This is the starting point for using DGX Spark as the canonical long-context
prefill/verifier and an RTX 3090 or RTX 4080 box as a faster draft/decode
worker.

## Shape

- Spark runs `DeepSeek-V4-Flash-Spark` and owns the session, tokenizer boundary,
  long prompt prefill, accepted-token state, final verification, and public API.
- The RTX worker runs a smaller or faster draft backend behind
  `runtime/scripts/split_spec_worker.py`.
- `runtime/scripts/split_spec_probe.py` probes the configured RTX workers and
  selects the fastest ready decode worker by measured `tok/s`.
- The first transport is prompt-tail plus accepted-token deltas. Raw KV or layer
  state transfer stays out of the hot path until bandwidth and serialization are
  measured.

This is a foundation, not a production speculative decoder. The worker can draft
candidate text today. Token-ID proposals and Spark-side accept/reject plumbing
are the next integration step.

## Files

- `runtime/configs/split-spec-decode.example.json` defines Spark plus the RTX
  3090/4080 workers.
- `runtime/scripts/split_spec_probe.py` checks Spark, probes enabled workers,
  and selects the fastest ready worker.
- `runtime/scripts/split_spec_worker.py` runs on the RTX host and exposes
  `/health`, `/v1/spec/probe`, and `/v1/spec/draft`.

## Spark Side

Copy the example config and replace the worker hostnames with real LAN or
Tailscale addresses:

```bash
cp runtime/configs/split-spec-decode.example.json runtime/configs/split-spec-decode.local.json
```

Enable one or both workers in the local JSON file. Then run:

```bash
python3 runtime/scripts/split_spec_probe.py \
  --config runtime/configs/split-spec-decode.local.json \
  --run-decode-probe
```

Use `--dry-run` to validate the config without network calls:

```bash
python3 runtime/scripts/split_spec_probe.py --dry-run
```

## RTX Worker Side

Start an OpenAI-compatible draft model server on the RTX box, then put the worker
stub in front of it:

```bash
SPLIT_SPEC_WORKER_NAME=rtx4080 \
SPLIT_SPEC_GPU="RTX 4080" \
SPLIT_SPEC_BACKEND_URL=http://127.0.0.1:8000 \
SPLIT_SPEC_MODEL=your-draft-model-name \
SPLIT_SPEC_PORT=8108 \
python3 runtime/scripts/split_spec_worker.py
```

For a manually benchmarked worker that is not wired to a backend yet, publish a
health score only:

```bash
SPLIT_SPEC_WORKER_NAME=rtx3090 \
SPLIT_SPEC_GPU="RTX 3090" \
SPLIT_SPEC_READY=1 \
SPLIT_SPEC_DECODE_TOK_S=120 \
python3 runtime/scripts/split_spec_worker.py
```

## Acceptance Gate

Do not treat worker output as accepted model output until all of these are true:

- Worker and Spark use compatible tokenization for candidate IDs.
- Worker returns `candidate_token_ids`, not text only.
- Spark verifies proposed tokens against `DeepSeek-V4-Flash-Spark`.
- Rejected tokens fall back to Spark decode without corrupting session state.
- Probe logs record worker GPU, model, prompt, completion tokens, elapsed time,
  and measured decode tok/s.

## Why Not Raw KV First

Spark's value here is holding the large model and long-context state. Moving raw
KV or layer state back and forth for every token can erase the decode win unless
the link and serializer are proven fast enough. The safer first interface is a
remote draft worker that sends compact token proposals while Spark stays the
canonical verifier.
