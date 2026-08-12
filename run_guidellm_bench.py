#!/usr/bin/env python3
"""GuideLLM benchmark runner — OGX Performance Characterization.

Aligns with the OGX Agentic API Performance Characterization Test Plan:
  - 10 concurrency levels: 1, 4, 16, 64, 128, 256, 384, 512, 768, 1024
  - 3 payload sizes: small (50/50), medium (500/500), large (2000/2000) tokens
  - 3 methods: direct (simulator), chat-completion (OGX), response API (OGX)
  - Streaming primary mode
  - 5 min per stage, 30s warm-up excluded

Telemetry (automatic per run):
  - Prometheus metrics (aggregates + time-series) collected over the run window
  - Grafana annotations pushed at test start/end for dashboard segmentation
  - MLflow: GuideLLM JSON + Prometheus data logged as artifacts
    MLFLOW_EXPERIMENT = OGX-<method>-<sim-profile>  (e.g. OGX-chat-fast)
    MLFLOW_RUN_NAME   = <method>-<payload>-<ts>     (e.g. chat-small-20260708)

Usage:
  python run_guidellm_bench.py --method chat --sim-profile fast --payload small
  python run_guidellm_bench.py --method direct --sim-profile fast --payload all
  python run_guidellm_bench.py --method chat --sim-profile fast --quick
  python run_guidellm_bench.py --method chat --sim-profile fast --no-mlflow
"""
import argparse
import os
import subprocess
import sys
import time

os.environ["HOME"] = "/tmp"
os.environ["HF_HOME"] = "/tmp/hf_cache"
os.environ["TRANSFORMERS_CACHE"] = "/tmp/hf_cache"
os.environ["GIT_PYTHON_REFRESH"] = "quiet"
sys.path.insert(0, "/tmp/pylib")
os.environ["PYTHONPATH"] = (
    "/tmp/guidellm-upgrade:" + os.environ.get("PYTHONPATH", "")
)
os.environ["PATH"] = (
    "/tmp/guidellm-upgrade/bin:/opt/guidellm/bin:/tmp/pylib/bin:"
    + os.environ.get("PATH", "")
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from scripts.prom_collector import (  # noqa: E402
    PrometheusClient,
    GrafanaAnnotator,
    collect_aggregates,
    collect_timeseries,
    collect_raw_dump,
    save_prom_data,
    save_raw_dump,
    epoch_ms,
)

LLAMA_STACK_URL = os.environ.get(
    "LLAMA_STACK_URL",
    "http://ogx-server-service:8321",
)
VLLM_URL = os.environ.get("VLLM_URL", "http://vllm-inference:8000")
VLLM_MODEL = os.environ.get("VLLM_MODEL_ID", "simulator")
OGX_MODEL = os.environ.get("OGX_MODEL_ID", "vllm-sim/simulator")
TOKENIZER = os.environ.get("GUIDELLM_TOKENIZER", "gpt2")
NAMESPACE = os.environ.get("PERF_NAMESPACE", "perf-testing")

CONCURRENCY_LEVELS = [1, 4, 16, 64, 128, 256, 384, 512, 768, 1024]
QUICK_CONCURRENCY = [1, 16, 128]

PAYLOADS = {
    "small": (50, 50),
    "medium": (500, 500),
    "large": (2000, 2000),
}

SIM_PROFILES = {
    "fast":      {"ttft_ms": 130,  "itl_ms": 7},
    "moderate":  {"ttft_ms": 400,  "itl_ms": 30},
    "realistic": {"ttft_ms": 3700, "itl_ms": 85},
}

METHODS = {
    "direct": {
        "desc": "Direct Baseline (simulator, no OGX)",
        "target": VLLM_URL,
        "model": VLLM_MODEL,
        "request_format": "/v1/chat/completions",
    },
    "chat": {
        "desc": "OGX Chat-Completion API",
        "target": LLAMA_STACK_URL,
        "model": OGX_MODEL,
        "request_format": "/v1/chat/completions",
    },
    "response": {
        "desc": "OGX Response API (agentic)",
        "target": LLAMA_STACK_URL,
        "model": OGX_MODEL,
        "request_format": "/v1/responses",
    },
}

MLFLOW_LOGGER = os.path.join(
    SCRIPT_DIR, "scripts", "log_guidellm_to_mlflow.py",
)

PROM_SCRAPE_WAIT = 20  # seconds to wait for final Prometheus scrape


def build_cmd(method, prompt_tok, output_tok,
              rate, duration_s, output_path):
    """Build the ``guidellm run`` command for a single concurrency level."""
    m = METHODS[method]
    backend_parts = [
        "kind=openai_http",
        f"target={m['target']}",
        f"model={m['model']}",
        f"request_format={m['request_format']}",
        "http2=false",
        "validate_backend=false",
    ]
    return [
        "guidellm", "run",
        "--backend", ",".join(backend_parts),
        "--tokenizer", f"kind=hf_auto,model={TOKENIZER}",
        "--data", (
            f"kind=synthetic_text,"
            f"prompt_tokens={prompt_tok},"
            f"output_tokens={output_tok}"
        ),
        "--profile", f"kind=concurrent,streams={rate}",
        "--constraint", f"kind=max_duration,seconds={duration_s}",
        "--output", f"kind=json,path={output_path}",
    ]


# ─── MLflow logging ──────────────────────────────────────────────────────────

def log_to_mlflow(guidellm_json, prom_json,
                  method, sim_profile, payload_name):
    """Call the MLflow logger, then attach the Prometheus data file."""
    if not os.environ.get("MLFLOW_TRACKING_URI"):
        print("  [MLflow] MLFLOW_TRACKING_URI not set — skipping")
        return

    if not os.path.exists(MLFLOW_LOGGER):
        print(
            f"  [MLflow] Logger not found at {MLFLOW_LOGGER} — skipping"
        )
        return

    ts = time.strftime("%Y%m%d-%H%M%S")
    experiment = f"OGX-{method}-{sim_profile}"
    basename = os.path.splitext(os.path.basename(guidellm_json))[0]
    c_tag = ""
    if "-c" in basename:
        c_tag = basename.rsplit("-c", 1)[-1]
    run_name = f"{method}-{payload_name}-c{c_tag}" if c_tag else \
               f"{method}-{payload_name}-{ts}"

    env = os.environ.copy()
    env["MLFLOW_EXPERIMENT"] = experiment
    env["MLFLOW_RUN_NAME"] = run_name
    workspace = env.get("MLFLOW_WORKSPACE", "")
    if not workspace:
        print("  [MLflow] ERROR: MLFLOW_WORKSPACE is not set. "
              "Set it in your environment or config.env.")
        return
    env["MLFLOW_WORKSPACE"] = workspace

    profile_delays = SIM_PROFILES.get(sim_profile, {})
    env["MLFLOW_EXTRA_PARAMS"] = (
        f"sim_profile={sim_profile},"
        f"sim_ttft_ms={profile_delays.get('ttft_ms', '')},"
        f"sim_itl_ms={profile_delays.get('itl_ms', '')}"
    )

    extra_artifacts = []
    if prom_json and os.path.exists(prom_json):
        extra_artifacts.append(prom_json)
        raw_dump = prom_json.replace("-prom.json", "-prom-raw.json")
        if os.path.exists(raw_dump):
            extra_artifacts.append(raw_dump)

    print(
        f"  [MLflow] experiment={experiment}  "
        f"run={run_name}  workspace={env['MLFLOW_WORKSPACE']}"
    )

    cmd = [sys.executable, MLFLOW_LOGGER, guidellm_json]
    for art in extra_artifacts:
        cmd.extend(["--extra-artifact", art])

    result = subprocess.run(
        cmd, capture_output=True, text=True, env=env,
    )

    if result.returncode == 0:
        for line in result.stdout.strip().splitlines():
            print(f"  [MLflow] {line}")
    else:
        print(f"  [MLflow] ERROR (exit {result.returncode})")
        if result.stderr:
            for line in result.stderr.strip().splitlines()[-5:]:
                print(f"  [MLflow] {line}")


# ─── Single benchmark run ────────────────────────────────────────────────────

def _cleanup_guidellm():
    """Kill orphaned GuideLLM processes and remove stale sockets."""
    import glob as _glob
    for stale in _glob.glob("/tmp/pymp-*"):
        subprocess.run(["rm", "-rf", stale], capture_output=True)
    subprocess.run(
        ["bash", "-c", "pkill -9 -f 'guidellm run' 2>/dev/null || true"],
        capture_output=True,
    )
    time.sleep(0.5)


def run_bench(method, payload_name, prompt_tok, output_tok,
              concurrency, duration_s, output_dir, sim_profile,
              prom, grafana):
    """Run GuideLLM per-level, collect Prom, annotate Grafana, log to MLflow."""
    import shlex

    ts = time.strftime("%Y%m%d-%H%M%S")
    m = METHODS[method]
    base_name = f"guidellm-{method}-{payload_name}-{sim_profile}-{ts}"
    prom_path = os.path.join(output_dir, f"{base_name}-prom.json")

    test_label = f"{method}/{payload_name}/{sim_profile}"
    annotation_tags = [
        "benchmark", "guidellm", method, payload_name, sim_profile,
    ]

    # ── Header ──
    print(f"\n{'=' * 70}")
    print(f"  {m['desc']}")
    print(f"  Sim Profile:  {sim_profile}")
    print(f"  Payload:      {payload_name} "
          f"({prompt_tok}/{output_tok} tokens)")
    print(f"  Target:       {m['target']}")
    print(f"  Model:        {m['model']}")
    print(f"  Concurrency:  {concurrency}")
    print(f"  Duration:     {duration_s}s per level")
    print(f"  MLflow Exp:   OGX-{method}-{sim_profile}")
    if grafana.enabled:
        print("  Grafana:      annotations enabled")
    if prom.available:
        print("  Prometheus:   collection enabled")
    print(f"{'=' * 70}\n")

    # ── Grafana: mark suite start ──
    start_ms = epoch_ms()
    start_unix = time.time()
    grafana.annotate(
        start_ms,
        f"START: {test_label}",
        annotation_tags + ["start"],
    )

    # ── Run each concurrency level separately ──
    output_files = []
    worst_rc = 0
    for rate in concurrency:
        level_name = f"{base_name}-c{rate}"
        output_path = os.path.join(output_dir, f"{level_name}.json")

        _cleanup_guidellm()

        cmd = build_cmd(
            method, prompt_tok, output_tok,
            rate, duration_s, output_path,
        )
        cmd_str = " ".join(shlex.quote(c) for c in cmd)
        print(f"\n--- concurrency={rate} ---")
        print(f"CMD: {cmd_str}\n")
        sys.stdout.flush()

        result = subprocess.run(
            ["bash", "-c", cmd_str],
            env=os.environ,
        )
        print(f"\nguidellm exit code: {result.returncode} (c={rate})")
        sys.stdout.flush()

        if result.returncode != 0:
            worst_rc = result.returncode
        if os.path.exists(output_path):
            output_files.append(output_path)

    end_unix = time.time()
    end_ms = epoch_ms()

    _cleanup_guidellm()

    # ── Grafana: mark test end (region annotation) ──
    run_duration = int(end_unix - start_unix)
    grafana.annotate(
        start_ms,
        f"{test_label}  |  {run_duration}s",
        annotation_tags + ["run-region"],
        end_ms,
    )

    # ── Collect Prometheus metrics (single window, all stages) ──
    prom_collected = False
    if prom.available:
        print(f"\n  [Prom] Waiting {PROM_SCRAPE_WAIT}s for final scrape...")
        time.sleep(PROM_SCRAPE_WAIT)

        print("  [Prom] Collecting aggregates...")
        aggregates = collect_aggregates(
            prom, start_unix, end_unix, NAMESPACE,
        )
        agg_count = sum(1 for v in aggregates.values() if v is not None)

        print("  [Prom] Collecting time-series...")
        timeseries = collect_timeseries(
            prom, start_unix, end_unix, NAMESPACE,
        )
        ts_count = sum(len(pts) for pts in timeseries.values())

        prom_metadata = {
            "method": method,
            "payload": payload_name,
            "sim_profile": sim_profile,
            "model": m['model'],
            "concurrency_levels": concurrency,
            "duration_per_level_s": duration_s,
        }

        save_prom_data(
            prom_path,
            start_unix, end_unix,
            aggregates, timeseries,
            metadata=prom_metadata,
        )
        prom_collected = True
        print(
            f"  [Prom] Saved {agg_count} aggregates, "
            f"{ts_count} time-series points → {prom_path}"
        )

        print("  [Prom] Collecting full raw dump (all metrics)...")
        raw_dump_path = prom_path.replace("-prom.json", "-prom-raw.json")
        raw = collect_raw_dump(
            prom, start_unix, end_unix, NAMESPACE,
        )
        save_raw_dump(
            raw_dump_path, start_unix, end_unix,
            raw, metadata=prom_metadata,
        )
        print(
            f"  [Prom] Raw dump: {len(raw)} series → {raw_dump_path}"
        )
    else:
        print("  [Prom] Not available — skipping metric collection")

    # ── Log each result to MLflow ──
    for output_path in output_files:
        print(f"Results saved to {output_path}")
        log_to_mlflow(
            output_path,
            prom_path if prom_collected else None,
            method, sim_profile, payload_name,
        )

    if not output_files:
        print("WARNING: no output files were created")

    return worst_rc


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="GuideLLM benchmark — OGX Performance Characterization",
    )
    parser.add_argument(
        "--method", choices=["direct", "chat", "response"],
        default="chat",
        help="Test method: direct (Phase 1), chat (Phase 2), "
             "response (Phase 3). Default: chat",
    )
    parser.add_argument(
        "--sim-profile",
        choices=["fast", "moderate", "realistic"],
        default="fast",
        help="Simulator delay profile. Default: fast",
    )
    parser.add_argument(
        "--payload", choices=["small", "medium", "large", "all"],
        default="small",
        help="Payload size: small (50/50), medium (500/500), "
             "large (2000/2000), or all. Default: small",
    )
    parser.add_argument(
        "--duration", type=int, default=300,
        help="Seconds per concurrency level. Default: 300 (5 min)",
    )
    parser.add_argument(
        "--quick", action="store_true",
        help="Quick smoke test: 60s, fewer concurrency levels",
    )
    parser.add_argument(
        "--output-dir", default="/tmp/results",
        help="Directory for output files. Default: /tmp/results",
    )
    parser.add_argument(
        "--no-mlflow", action="store_true",
        help="Skip MLflow logging",
    )
    parser.add_argument(
        "--max-concurrency", type=int, default=None,
        help="Cap concurrency levels at this value (e.g. 512 for large payloads)",
    )
    args = parser.parse_args()

    if args.quick:
        concurrency = QUICK_CONCURRENCY
        duration = args.duration if args.duration else 60
    else:
        concurrency = CONCURRENCY_LEVELS
        duration = args.duration if args.duration else FULL_DURATION

    if args.max_concurrency:
        concurrency = [c for c in concurrency if c <= args.max_concurrency]

    if args.no_mlflow:
        os.environ.pop("MLFLOW_TRACKING_URI", None)

    os.makedirs(args.output_dir, exist_ok=True)

    # ── Init Prometheus + Grafana ──
    prom = PrometheusClient()
    if prom.connect():
        print("[Prom] Connected to Prometheus")
    else:
        print("[Prom] Not available — will skip metric collection")

    grafana = GrafanaAnnotator(NAMESPACE)
    if grafana.enabled:
        print("[Grafana] Annotations enabled")
    else:
        print("[Grafana] Not available — will skip annotations")

    # ── Resolve payloads ──
    payloads = (
        list(PAYLOADS.items())
        if args.payload == "all"
        else [(args.payload, PAYLOADS[args.payload])]
    )

    # ── Suite-level annotation ──
    suite_start = epoch_ms()
    suite_tags = [
        "benchmark", "guidellm", args.method,
        args.sim_profile, "suite",
    ]
    grafana.annotate(
        suite_start,
        f"SUITE START: {args.method} / {args.sim_profile} "
        f"({len(payloads)} payloads)",
        suite_tags,
    )

    # ── Run benchmarks ──
    total = len(payloads)
    failures = 0
    for i, (pname, (ptok, otok)) in enumerate(payloads, 1):
        print(
            f"\n>>> Configuration {i}/{total}: "
            f"{args.method} / {pname} / {args.sim_profile}"
        )
        rc = run_bench(
            args.method, pname, ptok, otok,
            concurrency, duration, args.output_dir,
            args.sim_profile, prom, grafana,
        )
        if rc != 0:
            failures += 1

    # ── Suite-level closing annotation ──
    suite_end = epoch_ms()
    suite_duration = (suite_end - suite_start) // 1000
    grafana.annotate(
        suite_start,
        f"SUITE: {args.method}/{args.sim_profile}  "
        f"{total - failures}/{total} ok  {suite_duration}s",
        suite_tags + ["run-region"],
        suite_end,
    )

    print(f"\n{'=' * 70}")
    print(f"  Benchmark complete: {total - failures}/{total} succeeded")
    print(f"  MLflow experiment:  OGX-{args.method}-{args.sim_profile}")
    print(f"  Results in:         {args.output_dir}")
    if prom.available:
        print("  Prometheus data:    collected and logged")
    if grafana.enabled:
        print("  Grafana:            annotations created")
    print(f"{'=' * 70}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
