# 2026-05-27 K144/K160 Context Sweeps

## K144 No-Spec

Run directory on Spark:

```text
/home/sero/spark/benchmarks/deepseek-reap/single-server-sweep/k144-nospec-200k-mnbt8192-20260527T190139Z
```

Config:

```text
KV_CACHE_MEMORY_BYTES=14G
MAX_NUM_BATCHED_TOKENS=8192
MAX_NUM_SEQS=1
ENFORCE_EAGER=0
SPECULATIVE_CONFIG=
```

Result:

```text
200K long_needle prompt_tokens: 186,390
TTFT: 345.8336799179997
prefill_tokens_per_s: 538.9584960151792
decode_tokens_per_s: 13.899317875260461
needle_retained: true
```

Caveat: the 200K sweep completed, but the watchdog logged a low-memory kill at final teardown near the 8 GiB threshold. Treat this as proof that K144 can serve 200K, not as the most comfortable daemon profile.

## K160 MTP2

Run directory on Spark:

```text
/home/sero/spark/benchmarks/deepseek-reap/single-server-sweep/k160-mtp2-200k-mnbt4096-kv6g-20260527T192208Z
```

Config:

```text
KV_CACHE_MEMORY_BYTES=6G
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=1
ENFORCE_EAGER=0
SPECULATIVE_CONFIG={"method":"deepseek_mtp","num_speculative_tokens":2}
```

Result:

```text
200K long_needle prompt_tokens: 186,390
TTFT: 362.57324563699876
prefill_tokens_per_s: 514.0754378402482
decode_tokens_per_s: 24.378220294319892
needle_retained: true
watchdog_kill: false
```

Fixed long-coding rerun:

```text
/home/sero/spark/benchmarks/deepseek-reap/single-server-sweep/k160-mtp2-200k-longcoding-fixed-20260527T194241Z
prompt_tokens: 182,112
TTFT: 353.79875925300075
prefill_tokens_per_s: 514.7332918422478
decode_tokens_per_s: 18.94587006354192
mentions_off_by_one: true
```
