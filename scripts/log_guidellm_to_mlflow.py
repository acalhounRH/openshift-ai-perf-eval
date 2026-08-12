#!/usr/bin/env python3
"""Log GuideLLM benchmark metrics + Prometheus data to MLflow.

Reads a GuideLLM JSON results file, extracts key performance metrics
from each benchmark, and logs them as an MLflow run.  Optionally
attaches Prometheus aggregate metrics and time-series data collected
during the benchmark window.

Environment variables:
    MLFLOW_TRACKING_URI      – MLflow server URL  (required)
    MLFLOW_TRACKING_USERNAME – basic-auth user     (required)
    MLFLOW_TRACKING_PASSWORD – basic-auth pass     (required)
    MLFLOW_EXPERIMENT        – experiment name     (default: guidellm)
    MLFLOW_RUN_NAME          – run name            (default: from filename)
    MLFLOW_WORKSPACE         – workspace name      (optional)

Usage:
    python3 scripts/log_guidellm_to_mlflow.py results.json
    python3 scripts/log_guidellm_to_mlflow.py results.json \\
        --extra-artifact results-prom.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, "/tmp/pylib")

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

import mlflow  # noqa: E402

STAT_KEYS = ("mean", "median", "min", "max", "std_dev")
PERCENTILE_KEYS = ("p50", "p90", "p95", "p99")

METRICS_TO_LOG = (
    "time_to_first_token_ms",
    "time_per_output_token_ms",
    "inter_token_latency_ms",
    "output_tokens_per_second",
    "tokens_per_second",
    "request_latency",
    "requests_per_second",
    "request_concurrency",
    "prompt_token_count",
    "output_token_count",
    "total_token_count",
)


def extract_flat_metrics(metrics: dict) -> dict[str, float]:
    """Turn nested GuideLLM metrics into flat key=value pairs."""
    flat: dict[str, float] = {}

    totals = metrics.get("request_totals", {})
    for k in ("successful", "errored", "incomplete", "total"):
        if k in totals:
            flat[f"requests.{k}"] = totals[k]

    for name in METRICS_TO_LOG:
        bucket = metrics.get(name, {}).get("successful")
        if not isinstance(bucket, dict) or not bucket.get("count"):
            continue
        for sk in STAT_KEYS:
            if sk in bucket and bucket[sk] is not None:
                flat[f"{name}.{sk}"] = bucket[sk]
        pcts = bucket.get("percentiles", {})
        for pk in PERCENTILE_KEYS:
            if pk in pcts and pcts[pk] is not None:
                flat[f"{name}.{pk}"] = pcts[pk]

    return flat


def extract_params(benchmark: dict, config: dict) -> dict[str, str]:
    """Pull run-level parameters from the benchmark config."""
    params: dict[str, str] = {}

    backend = benchmark.get("config", {}).get("backend", {})
    params["model"] = backend.get("model", "unknown")
    params["backend_target"] = backend.get("target", "unknown")
    if backend.get("request_format"):
        params["request_format"] = backend["request_format"]

    strategy = benchmark.get("config", {}).get("strategy", {})
    params["concurrency"] = str(strategy.get("streams", ""))
    params["max_concurrency"] = str(
        strategy.get("max_concurrency", "")
    )

    labels = config.get("metadata", {}).get("labels", {})
    if labels.get("name"):
        params["benchmark_name"] = labels["name"]

    params["guidellm_version"] = (
        config.get("_root", {}).get("guidellm_version", "")
    )

    if benchmark.get("duration") is not None:
        params["duration_s"] = str(round(benchmark["duration"], 1))

    return {k: v for k, v in params.items() if v}


def extract_prom_metrics(prom_path: str) -> dict[str, float]:
    """Read Prometheus aggregates from the prom data file and return
    as flat metrics prefixed with ``prom.`` for MLflow."""
    flat: dict[str, float] = {}
    try:
        with open(prom_path, encoding="utf-8") as f:
            data = json.load(f)
        aggregates = data.get("aggregates", {})
        for key, val in aggregates.items():
            if val is not None and math.isfinite(val):
                flat[f"prom.{key}"] = val
        window = data.get("window", {})
        if window.get("duration_s"):
            flat["prom.window_duration_s"] = window["duration_s"]
    except Exception:
        pass
    return flat


def extract_prom_params(prom_path: str) -> dict[str, str]:
    """Read metadata from the prom data file for MLflow params."""
    params: dict[str, str] = {}
    try:
        with open(prom_path, encoding="utf-8") as f:
            data = json.load(f)
        meta = data.get("metadata", {})
        for key in ("method", "payload", "sim_profile", "model"):
            if meta.get(key):
                params[key] = str(meta[key])
        if meta.get("concurrency_levels"):
            params["concurrency_levels"] = ",".join(
                str(c) for c in meta["concurrency_levels"]
            )
        if meta.get("duration_per_level_s"):
            params["duration_per_level_s"] = str(
                meta["duration_per_level_s"]
            )
    except Exception:
        pass
    return params


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Log GuideLLM results to MLflow",
    )
    parser.add_argument(
        "json_file",
        help="Path to GuideLLM JSON results file",
    )
    parser.add_argument(
        "--extra-artifact",
        action="append",
        default=[],
        help="Additional files to log as MLflow artifacts "
             "(e.g. Prometheus data JSON). Can be specified "
             "multiple times.",
    )
    args = parser.parse_args()

    for var in (
        "MLFLOW_TRACKING_URI",
        "MLFLOW_TRACKING_USERNAME",
        "MLFLOW_TRACKING_PASSWORD",
    ):
        if not os.environ.get(var):
            print(f"error: {var} is not set", file=sys.stderr)
            return 1

    os.environ["MLFLOW_TRACKING_INSECURE_TLS"] = "true"
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])

    workspace = os.environ.get("MLFLOW_WORKSPACE")
    if workspace:
        mlflow.set_workspace(workspace)

    experiment_name = os.environ.get("MLFLOW_EXPERIMENT", "guidellm")
    experiment = mlflow.get_experiment_by_name(experiment_name)
    if experiment:
        experiment_id = experiment.experiment_id
    else:
        experiment_id = mlflow.create_experiment(experiment_name)

    with open(args.json_file, encoding="utf-8") as f:
        data = json.load(f)

    root_meta = data.get("metadata", {})
    config = data.get("config", {})
    config["_root"] = root_meta
    benchmarks = data.get("benchmarks", [])

    if not benchmarks or benchmarks[0] is None:
        print("error: no benchmarks found in file", file=sys.stderr)
        return 1

    default_run_name = os.path.splitext(
        os.path.basename(args.json_file)
    )[0]
    run_name = os.environ.get("MLFLOW_RUN_NAME", default_run_name)

    # Collect Prometheus metrics from extra artifacts
    prom_metrics: dict[str, float] = {}
    prom_params: dict[str, str] = {}
    for art in args.extra_artifact:
        if art.endswith("-prom.json") and os.path.exists(art):
            prom_metrics.update(extract_prom_metrics(art))
            prom_params.update(extract_prom_params(art))

    for idx, bench in enumerate(benchmarks):
        if bench is None:
            continue

        name = (
            run_name if len(benchmarks) == 1
            else f"{run_name}-{idx}"
        )
        metrics = extract_flat_metrics(bench.get("metrics", {}))
        params = extract_params(bench, config)

        # Merge Prometheus data
        params.update(prom_params)
        metrics.update(prom_metrics)

        # Merge extra params passed via env (sim profile delays, etc.)
        extra_raw = os.environ.get("MLFLOW_EXTRA_PARAMS", "")
        if extra_raw:
            for kv in extra_raw.split(","):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    if v:
                        params[k.strip()] = v.strip()

        with mlflow.start_run(
            experiment_id=experiment_id, run_name=name,
        ):
            mlflow.log_params(params)
            mlflow.log_metrics(metrics)
            mlflow.log_artifact(args.json_file)
            for art in args.extra_artifact:
                if os.path.exists(art):
                    mlflow.log_artifact(art)

        prom_count = len(prom_metrics)
        print(
            f"run '{name}': logged {len(params)} params, "
            f"{len(metrics)} metrics "
            f"({prom_count} from Prometheus), "
            f"{1 + len(args.extra_artifact)} artifacts"
        )

    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
