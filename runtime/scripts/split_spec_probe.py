#!/usr/bin/env python3
"""Probe Spark plus remote RTX draft workers for split speculative decode.

This script is intentionally conservative. It measures only configured worker
endpoints and picks a remote worker when it reports ready plus a decode score.
It does not infer that a worker can participate in speculative decoding unless
the endpoint says so.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = (
    Path(__file__).resolve().parents[1]
    / "configs"
    / "split-spec-decode.example.json"
)


@dataclass
class HttpResult:
    ok: bool
    status: int | None
    elapsed_s: float
    data: dict[str, Any] | None
    error: str | None = None


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def join_url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + "/" + path.lstrip("/")


def request_json(
    method: str,
    url: str,
    timeout_s: float,
    payload: dict[str, Any] | None = None,
) -> HttpResult:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8")
            elapsed = time.perf_counter() - start
            data = json.loads(raw) if raw else {}
            return HttpResult(True, resp.status, elapsed, data)
    except urllib.error.HTTPError as exc:
        elapsed = time.perf_counter() - start
        raw = exc.read().decode("utf-8", errors="replace")
        parsed: dict[str, Any] | None
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = None
        return HttpResult(False, exc.code, elapsed, parsed, raw or str(exc))
    except (OSError, TimeoutError, json.JSONDecodeError) as exc:
        elapsed = time.perf_counter() - start
        return HttpResult(False, None, elapsed, None, str(exc))


def model_ids(models_json: dict[str, Any] | None) -> list[str]:
    if not models_json:
        return []
    data = models_json.get("data")
    if not isinstance(data, list):
        return []
    ids: list[str] = []
    for entry in data:
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            ids.append(entry["id"])
    return ids


def probe_spark(
    spark_cfg: dict[str, Any],
    timeout_s: float,
    dry_run: bool,
) -> dict[str, Any]:
    base_url = str(spark_cfg["base_url"])
    expected_model = str(spark_cfg.get("model", ""))
    result: dict[str, Any] = {
        "name": spark_cfg.get("name", "spark"),
        "role": spark_cfg.get("role", "canonical-prefill-verifier"),
        "base_url": base_url,
        "expected_model": expected_model,
        "ok": False,
        "checked": not dry_run,
    }
    if dry_run:
        result["reason"] = "dry-run"
        return result

    health_path = str(spark_cfg.get("health_path", "/health"))
    models_path = str(spark_cfg.get("models_path", "/v1/models"))
    health = request_json("GET", join_url(base_url, health_path), timeout_s)
    models = request_json("GET", join_url(base_url, models_path), timeout_s)
    ids = model_ids(models.data)

    result.update(
        {
            "health_ok": health.ok,
            "health_status": health.status,
            "models_ok": models.ok,
            "models_status": models.status,
            "models": ids,
            "model_match": expected_model in ids if expected_model else bool(ids),
            "elapsed_s": round(health.elapsed_s + models.elapsed_s, 6),
        }
    )
    result["ok"] = bool(result["health_ok"] and result["models_ok"] and result["model_match"])
    if not result["ok"]:
        result["reason"] = health.error or models.error or "spark model check failed"
    return result


def decode_score(payload: dict[str, Any] | None) -> float | None:
    if not payload:
        return None
    for key in ("measured_decode_tok_s", "decode_tok_s", "tokens_per_second", "tok_s"):
        value = payload.get(key)
        if isinstance(value, (int, float)) and value > 0:
            return float(value)
    metrics = payload.get("metrics")
    if isinstance(metrics, dict):
        return decode_score(metrics)
    return None


def probe_worker(
    worker_cfg: dict[str, Any],
    probe_cfg: dict[str, Any],
    timeout_s: float,
    run_decode_probe: bool,
    dry_run: bool,
) -> dict[str, Any]:
    name = str(worker_cfg.get("name", "worker"))
    enabled = bool(worker_cfg.get("enabled", False))
    base_url = str(worker_cfg.get("base_url", ""))
    result: dict[str, Any] = {
        "name": name,
        "role": worker_cfg.get("role", "draft-decode-worker"),
        "gpu": worker_cfg.get("gpu"),
        "base_url": base_url,
        "enabled": enabled,
        "ok": False,
        "ready": False,
        "score": None,
        "checked": enabled and not dry_run,
    }
    if not enabled:
        result["reason"] = "disabled"
        return result
    if dry_run:
        result["reason"] = "dry-run"
        return result
    if not base_url:
        result["reason"] = "missing base_url"
        return result

    health = request_json("GET", join_url(base_url, "/health"), timeout_s)
    result.update(
        {
            "health_ok": health.ok,
            "health_status": health.status,
            "health_elapsed_s": round(health.elapsed_s, 6),
        }
    )
    if health.data:
        result["ready"] = bool(health.data.get("ready", health.data.get("ok", False)))
        result["capabilities"] = health.data.get("capabilities", [])
        result["token_id_acceptance_ready"] = bool(
            health.data.get("token_id_acceptance_ready", False)
        )
        result["reported_gpu"] = health.data.get("gpu")
        result["model"] = health.data.get("model")
        result["score"] = decode_score(health.data)
    if not health.ok:
        result["reason"] = health.error or "health request failed"
        return result

    if run_decode_probe:
        payload = {
            "prompt": probe_cfg.get("prompt", "Say exactly: split spec online."),
            "max_tokens": probe_cfg.get("max_tokens", 64),
            "temperature": probe_cfg.get("temperature", 0),
        }
        path = str(probe_cfg.get("path", "/v1/spec/probe"))
        probe = request_json("POST", join_url(base_url, path), timeout_s, payload)
        result.update(
            {
                "probe_ok": probe.ok,
                "probe_status": probe.status,
                "probe_elapsed_s": round(probe.elapsed_s, 6),
            }
        )
        if probe.data:
            result["probe"] = probe.data
            result["score"] = decode_score(probe.data) or result["score"]
            result["ready"] = bool(probe.data.get("ready", result["ready"]))
            result["token_id_acceptance_ready"] = bool(
                probe.data.get(
                    "token_id_acceptance_ready",
                    result.get("token_id_acceptance_ready", False),
                )
            )
        if not probe.ok:
            result["reason"] = probe.error or "decode probe failed"
            return result

    result["ok"] = bool(result["ready"] and result["score"])
    if not result["ok"]:
        result["reason"] = "worker did not report ready plus decode score"
    return result


def select_worker(workers: list[dict[str, Any]], require_ready: bool) -> dict[str, Any] | None:
    candidates = []
    for worker in workers:
        score = worker.get("score")
        if not isinstance(score, (int, float)) or score <= 0:
            continue
        if require_ready and not worker.get("ready"):
            continue
        candidates.append(worker)
    if not candidates:
        return None
    return max(candidates, key=lambda item: float(item["score"]))


def token_ids_ready(worker: dict[str, Any]) -> bool:
    if worker.get("token_id_acceptance_ready") is True:
        return True
    capabilities = worker.get("capabilities")
    return isinstance(capabilities, list) and "candidate-token-ids" in capabilities


def select_acceptable_worker(
    workers: list[dict[str, Any]],
    require_ready: bool,
    require_token_ids: bool,
) -> dict[str, Any] | None:
    candidates = []
    for worker in workers:
        score = worker.get("score")
        if not isinstance(score, (int, float)) or score <= 0:
            continue
        if require_ready and not worker.get("ready"):
            continue
        if require_token_ids and not token_ids_ready(worker):
            continue
        candidates.append(worker)
    if not candidates:
        return None
    return max(candidates, key=lambda item: float(item["score"]))


def print_text_report(report: dict[str, Any]) -> None:
    spark = report["spark"]
    print("spark:")
    print(f"  {spark['name']} {spark['base_url']} ok={spark['ok']}")
    if spark.get("models"):
        print(f"  models={', '.join(spark['models'])}")
    if spark.get("reason"):
        print(f"  reason={spark['reason']}")

    print("workers:")
    for worker in report["workers"]:
        score = worker.get("score")
        score_text = f"{score:.3f} tok/s" if isinstance(score, (int, float)) else "none"
        print(
            f"  {worker['name']} enabled={worker['enabled']} "
            f"ready={worker.get('ready', False)} score={score_text}"
        )
        if worker.get("reason"):
            print(f"    reason={worker['reason']}")

    selected = report.get("selected_worker")
    if selected:
        print(f"selected: {selected['name']} ({selected['score']:.3f} tok/s)")
    else:
        print("selected: none")


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    cfg = load_json(Path(args.config))
    timeout_s = float(args.timeout_s or cfg.get("selection", {}).get("timeout_s", 3.0))
    run_decode_probe = bool(
        args.run_decode_probe
        or cfg.get("probe", {}).get("run_decode_probe_by_default", False)
    )
    spark = probe_spark(cfg["spark"], timeout_s, args.dry_run)
    workers = [
        probe_worker(
            worker,
            cfg.get("probe", {}),
            timeout_s,
            run_decode_probe,
            args.dry_run,
        )
        for worker in cfg.get("workers", [])
    ]
    require_token_ids = bool(
        cfg.get("selection", {}).get("require_token_ids_for_acceptance", False)
    )
    selected = select_acceptable_worker(
        workers,
        bool(cfg.get("selection", {}).get("require_ready", True)),
        require_token_ids,
    )
    return {
        "config": str(Path(args.config)),
        "dry_run": args.dry_run,
        "run_decode_probe": run_decode_probe,
        "require_token_ids_for_acceptance": require_token_ids,
        "spark": spark,
        "workers": workers,
        "selected_worker": selected,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="split-spec JSON config")
    parser.add_argument("--timeout-s", type=float, default=None, help="HTTP timeout per request")
    parser.add_argument("--run-decode-probe", action="store_true", help="POST /v1/spec/probe on each enabled worker")
    parser.add_argument("--dry-run", action="store_true", help="load and summarize config without network calls")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--allow-no-worker", action="store_true", help="exit 0 even when no worker is selected")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    report = build_report(args)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text_report(report)
    if args.dry_run or args.allow_no_worker or report.get("selected_worker"):
        return 0
    return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
