#!/usr/bin/env python3
"""
06-load-test.py — Load test and scaling analysis for Llama Stack on OpenShift.

Modes:
  default   50 requests, 4-phase pattern (warm-up, sustained, burst, tail)
  quick     15 requests, lighter load
  heavy     100 requests, higher concurrency
  scale     Concurrency scaling test with per-level Prometheus metric collection

Creates Grafana annotations so each run is visible on dashboards.

Usage:
  python3 06-load-test.py                              # default mode
  python3 06-load-test.py --quick                      # quick mode
  python3 06-load-test.py --heavy                      # heavy mode
  python3 06-load-test.py --scale                      # scaling test
  python3 06-load-test.py --scale --levels 5 10 20 40 60 80 100 150 200 300 500 1000
  python3 06-load-test.py --tag "baseline-v1"          # custom annotation tag
"""

import argparse
import csv
import json
import math
import os
import ssl
import subprocess
import sys
import time
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field, fields, asdict
from datetime import datetime
from pathlib import Path
from typing import Optional

# ─── Colors ──────────────────────────────────────────────────────────────────

class C:
    INFO  = "\033[0;34m[INFO]\033[0m "
    OK    = "\033[0;32m[OK]\033[0m   "
    WARN  = "\033[1;33m[WARN]\033[0m "
    ERR   = "\033[0;31m[ERROR]\033[0m"
    RESET = "\033[0m"
    BOLD  = "\033[1m"

def info(msg):  print(f"{C.INFO} {msg}")
def ok(msg):    print(f"{C.OK}  {msg}")
def warn(msg):  print(f"{C.WARN} {msg}")
def bail(msg):  print(f"{C.ERR} {msg}"); sys.exit(1)

# ─── OpenShift helpers ───────────────────────────────────────────────────────

def oc(*args, capture=True, check=True):
    """Run an oc command and return stdout."""
    result = subprocess.run(
        ["oc"] + list(args),
        capture_output=capture, text=True,
        timeout=300,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip() if capture else ""

def oc_exec_curl(namespace: str, deployment: str, url: str, method="GET",
                 data: Optional[dict] = None) -> dict:
    """Execute a curl inside a pod and return parsed JSON."""
    cmd = ["exec", f"deployment/{deployment}", "-n", namespace, "--",
           "curl", "-s", url]
    if method == "POST":
        cmd.extend(["-X", "POST", "-H", "Content-Type: application/json"])
        if data:
            cmd.extend(["-d", json.dumps(data)])
    result = subprocess.run(
        ["oc"] + cmd, capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        return {}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}

# ─── Prometheus client ───────────────────────────────────────────────────────

class PrometheusClient:
    def __init__(self):
        self.host = None
        self.token = None
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE

    def connect(self) -> bool:
        try:
            self.host = oc("get", "route", "thanos-querier",
                           "-n", "openshift-monitoring",
                           "-o", "jsonpath={.spec.host}")
            self.token = oc("create", "token", "prometheus-k8s",
                            "-n", "openshift-monitoring", "--duration=2h")
            return bool(self.host and self.token)
        except Exception as e:
            warn(f"Cannot connect to Prometheus: {e}")
            return False

    def query(self, promql: str, at_time: Optional[float] = None) -> Optional[float]:
        """Execute an instant query and return scalar value.
        If at_time is given, evaluates the query at that unix timestamp.
        """
        if not self.host:
            return None
        params = {"query": promql}
        if at_time is not None:
            params["time"] = str(at_time)
        url = f"https://{self.host}/api/v1/query?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}"})
        try:
            resp = urllib.request.urlopen(req, context=self._ctx, timeout=15)
            data = json.loads(resp.read())
            results = data.get("data", {}).get("result", [])
            if results:
                val = float(results[0]["value"][1])
                return val if math.isfinite(val) else None
        except Exception:
            pass
        return None

    def query_range_avg(self, promql: str, start: float, end: float,
                        step: int = 15) -> Optional[float]:
        """Execute a range query and return the average of all values.
        Useful for getting the mean of a metric over an exact time window.
        """
        if not self.host:
            return None
        params = urllib.parse.urlencode({
            "query": promql, "start": str(start),
            "end": str(end), "step": str(step),
        })
        url = f"https://{self.host}/api/v1/query_range?{params}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}"})
        try:
            resp = urllib.request.urlopen(req, context=self._ctx, timeout=15)
            data = json.loads(resp.read())
            results = data.get("data", {}).get("result", [])
            if results:
                values = [float(v[1]) for v in results[0]["values"]
                          if math.isfinite(float(v[1]))]
                if values:
                    return sum(values) / len(values)
        except Exception:
            pass
        return None

    def query_range_max(self, promql: str, start: float, end: float,
                        step: int = 15) -> Optional[float]:
        """Execute a range query and return the max value over the window."""
        if not self.host:
            return None
        params = urllib.parse.urlencode({
            "query": promql, "start": str(start),
            "end": str(end), "step": str(step),
        })
        url = f"https://{self.host}/api/v1/query_range?{params}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}"})
        try:
            resp = urllib.request.urlopen(req, context=self._ctx, timeout=15)
            data = json.loads(resp.read())
            results = data.get("data", {}).get("result", [])
            if results:
                values = [float(v[1]) for v in results[0]["values"]
                          if math.isfinite(float(v[1]))]
                if values:
                    return max(values)
        except Exception:
            pass
        return None

# ─── Grafana annotations ────────────────────────────────────────────────────

class GrafanaAnnotator:
    def __init__(self, namespace: str):
        self.enabled = False
        self.url = None
        try:
            host = oc("get", "route", "grafana", "-n", namespace,
                       "-o", "jsonpath={.spec.host}", check=False)
            if host:
                self.url = f"https://{host}"
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                req = urllib.request.Request(
                    f"{self.url}/api/annotations",
                    headers={"Authorization": "Basic YWRtaW46YWRtaW4="},
                )
                resp = urllib.request.urlopen(req, context=ctx, timeout=5)
                if resp.status == 200:
                    self.enabled = True
                    ok("Grafana annotations API reachable")
        except Exception:
            pass
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE

    def annotate(self, time_ms: int, text: str, tags: list[str],
                 time_end_ms: Optional[int] = None):
        if not self.enabled:
            return
        body = {"time": time_ms, "tags": tags, "text": text}
        if time_end_ms:
            body["timeEnd"] = time_end_ms
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{self.url}/api/annotations",
            data=data,
            headers={
                "Authorization": "Basic YWRtaW46YWRtaW4=",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            urllib.request.urlopen(req, context=self._ctx, timeout=5)
        except Exception:
            pass

def epoch_ms() -> int:
    return int(time.time() * 1000)

# ─── Metric definitions ─────────────────────────────────────────────────────

@dataclass
class ScaleMetrics:
    """All metrics collected per concurrency level."""
    concurrency: int = 0
    requests: int = 0
    elapsed_s: int = 0
    req_per_s: float = 0.0

    # Llama Stack: HTTP server latency
    ls_http_p50_ms: Optional[float] = None
    ls_http_p95_ms: Optional[float] = None
    ls_http_p99_ms: Optional[float] = None

    # Llama Stack: HTTP client (LS → vLLM)
    ls_client_p50_ms: Optional[float] = None
    ls_client_p95_ms: Optional[float] = None

    # Llama Stack: active requests, tokens, async ops
    ls_active_reqs: Optional[float] = None
    ls_tok_in_s: Optional[float] = None
    ls_tok_out_s: Optional[float] = None
    ls_async_store_s: Optional[float] = None
    ls_async_connect_s: Optional[float] = None
    ls_async_close_s: Optional[float] = None

    # Llama Stack: DB pool
    ls_db_used: Optional[float] = None
    ls_db_idle: Optional[float] = None

    # Llama Stack: process health
    ls_cpu_ratio: Optional[float] = None
    ls_threads: Optional[float] = None
    ls_fds: Optional[float] = None
    ls_req_size_p50: Optional[float] = None
    ls_resp_size_p50: Optional[float] = None

    # GenAI operation
    genai_dur_p50_s: Optional[float] = None
    genai_dur_p95_s: Optional[float] = None

    # vLLM engine
    vllm_ttft_p50_ms: Optional[float] = None
    vllm_tpot_p50_ms: Optional[float] = None
    vllm_e2e_p50_s: Optional[float] = None
    vllm_e2e_p95_s: Optional[float] = None
    vllm_kv_cache_pct: Optional[float] = None
    vllm_running: Optional[float] = None
    vllm_waiting: Optional[float] = None
    vllm_out_tok_s: Optional[float] = None

    # GPU
    gpu_util_pct: Optional[float] = None
    gpu_power_w: Optional[float] = None
    gpu_temp_c: Optional[float] = None
    gpu_tensor_pct: Optional[float] = None

    # Process resources: all components
    vllm_pod_cpu: Optional[float] = None
    vllm_pod_mem_mb: Optional[float] = None
    ls_pod_cpu: Optional[float] = None
    ls_pod_mem_mb: Optional[float] = None
    pg_pod_cpu: Optional[float] = None
    pg_pod_mem_mb: Optional[float] = None
    otel_pod_cpu: Optional[float] = None
    otel_pod_mem_mb: Optional[float] = None

    # Node utilization
    node_app_cpu_pct: Optional[float] = None
    node_app_mem_pct: Optional[float] = None
    node_gpu_cpu_pct: Optional[float] = None
    node_gpu_mem_pct: Optional[float] = None
    node_loadgen_cpu_pct: Optional[float] = None
    node_loadgen_mem_pct: Optional[float] = None
    node_cp_cpu_pct: Optional[float] = None

    errors: int = 0

# ─── Metric collector ───────────────────────────────────────────────────────

# Metrics are split into two categories:
#
# RATE metrics use rate() or histogram_quantile(rate()) — these need a
# "{window}" placeholder that gets replaced with the actual time range.
# They are queried as range queries averaged over the level's exact duration.
#
# GAUGE metrics are point-in-time values (queue depth, cache %, connections).
# These are queried as range queries returning the MAX during the level.

RATE_METRICS = {
    # Llama Stack HTTP server
    "ls_http_p50_ms": 'histogram_quantile(0.50, sum(rate(http_server_duration_milliseconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',
    "ls_http_p95_ms": 'histogram_quantile(0.95, sum(rate(http_server_duration_milliseconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',
    "ls_http_p99_ms": 'histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',

    # Llama Stack HTTP client (LS → vLLM)
    "ls_client_p50_ms": 'histogram_quantile(0.50, sum(rate(http_client_duration_milliseconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',
    "ls_client_p95_ms": 'histogram_quantile(0.95, sum(rate(http_client_duration_milliseconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',

    # Llama Stack: token throughput
    "ls_tok_in_s": 'sum(rate(gen_ai_client_token_usage_sum{{service_name="llama-stack",gen_ai_token_type="input"}}[{window}]))',
    "ls_tok_out_s": 'sum(rate(gen_ai_client_token_usage_sum{{service_name="llama-stack",gen_ai_token_type="output"}}[{window}]))',

    # Llama Stack: async operations
    "ls_async_store_s": 'sum(rate(asyncio_process_created_total{{service_name="llama-stack",name="store_chat_completion"}}[{window}]))',
    "ls_async_connect_s": 'sum(rate(asyncio_process_created_total{{service_name="llama-stack",name="try_connect"}}[{window}]))',
    "ls_async_close_s": 'sum(rate(asyncio_process_created_total{{service_name="llama-stack",name="close"}}[{window}]))',

    # Llama Stack: payload sizes
    "ls_req_size_p50": 'histogram_quantile(0.50, sum(rate(http_server_request_size_bytes_bucket{{service_name="llama-stack"}}[{window}])) by (le))',
    "ls_resp_size_p50": 'histogram_quantile(0.50, sum(rate(http_server_response_size_bytes_bucket{{service_name="llama-stack"}}[{window}])) by (le))',

    # GenAI operation duration
    "genai_dur_p50_s": 'histogram_quantile(0.50, sum(rate(gen_ai_client_operation_duration_seconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',
    "genai_dur_p95_s": 'histogram_quantile(0.95, sum(rate(gen_ai_client_operation_duration_seconds_bucket{{service_name="llama-stack"}}[{window}])) by (le))',

    # vLLM engine
    "_vllm_ttft_s": 'histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[{window}])) by (le))',
    "_vllm_tpot_s": 'histogram_quantile(0.50, sum(rate(vllm:time_per_output_token_seconds_bucket[{window}])) by (le))',
    "vllm_e2e_p50_s": 'histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[{window}])) by (le))',
    "vllm_e2e_p95_s": 'histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[{window}])) by (le))',
    "vllm_out_tok_s": 'sum(rate(vllm:generation_tokens_total[{window}]))',

    # Process CPU (rate-based)
    "vllm_pod_cpu": 'sum(rate(container_cpu_usage_seconds_total{{namespace="perf-testing",pod=~"vllm.*",container!=""}}[{window}]))',
    "ls_pod_cpu": 'sum(rate(container_cpu_usage_seconds_total{{namespace="perf-testing",pod=~"llama-stack.*",container!=""}}[{window}]))',
    "pg_pod_cpu": 'sum(rate(container_cpu_usage_seconds_total{{namespace="perf-testing",pod=~"postgresql.*",container!=""}}[{window}]))',
    "otel_pod_cpu": 'sum(rate(container_cpu_usage_seconds_total{{namespace="perf-testing",pod=~"otel.*",container!=""}}[{window}]))',

    # Node CPU (rate-based)
    "node_app_cpu_pct": '100 * avg(1 - rate(node_cpu_seconds_total{{mode="idle"}}[{window}]) * on(instance) group_left() label_replace(kube_node_labels{{label_node_role_kubernetes_io_app_worker=""}},"instance","$1","node","(.+)"))',
    "node_gpu_cpu_pct": '100 * avg(1 - rate(node_cpu_seconds_total{{mode="idle"}}[{window}]) * on(instance) group_left() label_replace(kube_node_labels{{label_node_role_kubernetes_io_gpu_worker=""}},"instance","$1","node","(.+)"))',
    "node_loadgen_cpu_pct": '100 * avg(1 - rate(node_cpu_seconds_total{{mode="idle"}}[{window}]) * on(instance) group_left() label_replace(kube_node_labels{{label_node_role_kubernetes_io_loadgen_worker=""}},"instance","$1","node","(.+)"))',
    "node_cp_cpu_pct": '100 * avg(1 - rate(node_cpu_seconds_total{{mode="idle"}}[{window}]) * on(instance) group_left() label_replace(kube_node_labels{{label_node_role_kubernetes_io_master=""}},"instance","$1","node","(.+)"))',
}

GAUGE_METRICS = {
    # Llama Stack: gauges (point-in-time, take max during level)
    "ls_active_reqs": 'http_server_active_requests{service_name="llama-stack"}',
    "ls_db_used": 'db_client_connections_usage{service_name="llama-stack",state="used"}',
    "ls_db_idle": 'db_client_connections_usage{service_name="llama-stack",state="idle"}',
    "ls_cpu_ratio": 'process_cpu_utilization_ratio{service_name="llama-stack"}',
    "ls_threads": 'process_thread_count{service_name="llama-stack"}',
    "ls_fds": 'process_open_file_descriptor_count{service_name="llama-stack"}',

    # vLLM gauges
    "vllm_kv_cache_pct": 'vllm:gpu_cache_usage_perc * 100',
    "vllm_running": 'vllm:num_requests_running',
    "vllm_waiting": 'vllm:num_requests_waiting',

    # GPU gauges
    "gpu_util_pct": 'avg(DCGM_FI_DEV_GPU_UTIL)',
    "gpu_power_w": 'avg(DCGM_FI_DEV_POWER_USAGE)',
    "gpu_temp_c": 'avg(DCGM_FI_DEV_GPU_TEMP)',
    "gpu_tensor_pct": 'avg(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE) * 100',

    # Memory gauges (point-in-time)
    "vllm_pod_mem_mb": 'sum(container_memory_working_set_bytes{namespace="perf-testing",pod=~"vllm.*",container!=""}) / 1048576',
    "ls_pod_mem_mb": 'sum(container_memory_working_set_bytes{namespace="perf-testing",pod=~"llama-stack.*",container!=""}) / 1048576',
    "pg_pod_mem_mb": 'sum(container_memory_working_set_bytes{namespace="perf-testing",pod=~"postgresql.*",container!=""}) / 1048576',
    "otel_pod_mem_mb": 'sum(container_memory_working_set_bytes{namespace="perf-testing",pod=~"otel.*",container!=""}) / 1048576',

    # Node memory gauges
    "node_app_mem_pct": '100 * avg(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * on(instance) group_left() label_replace(kube_node_labels{label_node_role_kubernetes_io_app_worker=""},"instance","$1","node","(.+)"))',
    "node_gpu_mem_pct": '100 * avg(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * on(instance) group_left() label_replace(kube_node_labels{label_node_role_kubernetes_io_gpu_worker=""},"instance","$1","node","(.+)"))',
    "node_loadgen_mem_pct": '100 * avg(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * on(instance) group_left() label_replace(kube_node_labels{label_node_role_kubernetes_io_loadgen_worker=""},"instance","$1","node","(.+)"))',
}


def collect_metrics(prom: PrometheusClient,
                    level_start: float, level_end: float) -> ScaleMetrics:
    """Query all metrics from Prometheus scoped to the level's time window.

    - Rate metrics: evaluated at level_end with a rate window matching the
      level duration, so rate() covers exactly the level's traffic.
    - Gauge metrics: range query returning the MAX value during the level,
      capturing peak concurrency/utilization during active load.
    """
    m = ScaleMetrics()

    duration_s = max(int(level_end - level_start), 15)
    # Prometheus rate() needs at least 2 scrape intervals; floor at 30s
    window = f"{max(duration_s, 30)}s"

    # Rate metrics: instant query at level_end with the right window
    for key, query_tpl in RATE_METRICS.items():
        query = query_tpl.format(window=window)
        val = prom.query(query, at_time=level_end)
        if key == "_vllm_ttft_s":
            m.vllm_ttft_p50_ms = val * 1000 if val is not None else None
        elif key == "_vllm_tpot_s":
            m.vllm_tpot_p50_ms = val * 1000 if val is not None else None
        elif not key.startswith("_"):
            setattr(m, key, val)

    # Gauge metrics: range query returning max during the level
    for key, query in GAUGE_METRICS.items():
        val = prom.query_range_max(query, level_start, level_end)
        setattr(m, key, val)

    return m

# ─── Request sender ─────────────────────────────────────────────────────────

PROMPTS_LONG = [
    "Explain the architecture of a modern observability platform covering metrics collection, trace propagation, log aggregation, and alerting pipelines.",
    "You are a performance engineer. Analyze this scenario: a Kubernetes cluster running an LLM inference service shows increasing p99 latency under load while p50 remains stable. GPU utilization is at 60 percent and KV cache usage is at 85 percent. What are the likely causes and recommended mitigations?",
    "Compare and contrast three approaches to serving large language models in production: single-instance vLLM, replicated vLLM behind a load balancer, and KServe with autoscaling. Cover latency, throughput, cost efficiency, and operational complexity.",
    "Describe how continuous batching works in vLLM and why it improves throughput compared to static batching. Include details about the scheduler, KV cache management, and preemption strategies.",
    "Explain the Responses API in Llama Stack. How does it differ from the chat completions API? What additional capabilities does it provide for tool use, multi-turn conversations, and agent workflows?",
]

PROMPTS_SHORT = [
    "What is tensor parallelism and how does it affect inference latency",
    "Explain the KV cache in transformer inference and why it matters for throughput",
    "How does continuous batching work in vLLM compared to static batching",
    "What metrics should you monitor for GPU memory pressure during LLM serving",
    "Describe the tradeoffs between prefill and decode phases in autoregressive generation",
    "What is the Responses API in Llama Stack",
    "Explain OpenTelemetry and how it helps with LLM observability",
    "What is Red Hat OpenShift AI and what does it provide",
]


def send_request(namespace: str, model: str, prompt: str, max_tokens: int) -> bool:
    """Send a chat completion request via oc exec. Returns True on success."""
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    })
    result = subprocess.run(
        ["oc", "exec", "deployment/llama-stack", "-n", namespace, "--",
         "curl", "-s", "http://localhost:8321/v1/chat/completions",
         "-H", "Content-Type: application/json", "-d", payload],
        capture_output=True, text=True, timeout=120,
    )
    return result.returncode == 0


def send_batch(namespace: str, model: str, count: int, max_tokens: int,
               prompts: list[str]) -> int:
    """Send `count` concurrent requests. Returns error count."""
    errors = 0
    with ThreadPoolExecutor(max_workers=count) as pool:
        futures = []
        for i in range(count):
            prompt = prompts[i % len(prompts)]
            futures.append(pool.submit(send_request, namespace, model, prompt, max_tokens))
        for f in as_completed(futures):
            if not f.result():
                errors += 1
    return errors

# ─── Formatting helpers ─────────────────────────────────────────────────────

def fmt(val, decimals=2) -> str:
    if val is None:
        return "N/A"
    try:
        v = float(val)
        if not math.isfinite(v):
            return "N/A"
        return f"{v:.{decimals}f}"
    except (TypeError, ValueError):
        return "N/A"

def fmti(val) -> str:
    return fmt(val, 0)

def safe(val) -> float:
    """Return float or NaN."""
    if val is None:
        return float("nan")
    try:
        v = float(val)
        return v if math.isfinite(v) else float("nan")
    except (TypeError, ValueError):
        return float("nan")

def is_valid(v: float) -> bool:
    return math.isfinite(v)

# ─── Report generator ───────────────────────────────────────────────────────

def print_scaling_report(results: list[ScaleMetrics], csv_path: str):
    """Print the full scaling report with all tables and analysis."""

    # ── Table 1: Llama Stack Latency & Overhead ──
    print("═" * 120)
    print("  LLAMA STACK EVALUATION")
    print("═" * 120)
    print()
    print("── Latency Breakdown ──")
    hdr = f"{'Conc':>5} │ {'LS HTTP':>8} {'LS HTTP':>9} {'LS HTTP':>9} │ {'LS→vLLM':>8} {'LS→vLLM':>9} │ {'Overhead':>9} {'Over%':>7}"
    sub = f"{'':>5} │ {'p50(ms)':>8} {'p95(ms)':>9} {'p99(ms)':>9} │ {'p50(ms)':>8} {'p95(ms)':>9} │ {'p50(ms)':>9} {'':>7}"
    print(hdr); print(sub); print("─" * 90)
    for m in results:
        http_p50 = safe(m.ls_http_p50_ms)
        client_p50 = safe(m.ls_client_p50_ms)
        overhead = http_p50 - client_p50 if is_valid(http_p50) and is_valid(client_p50) else float("nan")
        over_pct = (overhead / http_p50 * 100) if is_valid(overhead) and http_p50 > 0 else float("nan")
        print(f"{m.concurrency:>5} │ {fmt(m.ls_http_p50_ms):>8} {fmt(m.ls_http_p95_ms):>9} {fmt(m.ls_http_p99_ms):>9} │ "
              f"{fmt(m.ls_client_p50_ms):>8} {fmt(m.ls_client_p95_ms):>9} │ "
              f"{fmt(overhead):>9} {fmt(over_pct,1):>6}%")
    print()

    # ── Table 2: Llama Stack Token & Async ──
    print("── Token Throughput & Async Operations ──")
    print(f"{'Conc':>5} │ {'In tok/s':>9} {'Out tok/s':>10} │ {'Store/s':>8} {'Connect/s':>10} {'Close/s':>8} │ {'DB Used':>8} {'DB Idle':>8}")
    print("─" * 90)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.ls_tok_in_s):>9} {fmt(m.ls_tok_out_s):>10} │ "
              f"{fmt(m.ls_async_store_s,4):>8} {fmt(m.ls_async_connect_s,4):>10} {fmt(m.ls_async_close_s,4):>8} │ "
              f"{fmti(m.ls_db_used):>8} {fmti(m.ls_db_idle):>8}")
    print()

    # ── Table 3: Llama Stack Process Health ──
    print("── Process Health & Resources ──")
    print(f"{'Conc':>5} │ {'CPU Ratio':>10} {'Threads':>8} {'FDs':>6} │ {'Pod CPU':>8} {'Pod Mem':>9} │ {'Req p50':>9} {'Resp p50':>10}")
    print(f"{'':>5} │ {'':>10} {'':>8} {'':>6} │ {'(cores)':>8} {'(MB)':>9} │ {'(bytes)':>9} {'(bytes)':>10}")
    print("─" * 90)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.ls_cpu_ratio,5):>10} {fmti(m.ls_threads):>8} {fmti(m.ls_fds):>6} │ "
              f"{fmt(m.ls_pod_cpu,4):>8} {fmt(m.ls_pod_mem_mb,1):>9} │ "
              f"{fmti(m.ls_req_size_p50):>9} {fmti(m.ls_resp_size_p50):>10}")
    print()

    # ── Table 4: GenAI vs vLLM ──
    print("── GenAI Operation (inference round-trip from LS) ──")
    print(f"{'Conc':>5} │ {'GenAI p50':>10} {'GenAI p95':>10} {'vLLM E2E':>9} {'vLLM E2E':>9} │ {'Req/s':>7} {'Time':>6} {'Err':>5}")
    print(f"{'':>5} │ {'(s)':>10} {'(s)':>10} {'p50(s)':>9} {'p95(s)':>9} │ {'':>7} {'(s)':>6} {'':>5}")
    print("─" * 85)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.genai_dur_p50_s):>10} {fmt(m.genai_dur_p95_s):>10} "
              f"{fmt(m.vllm_e2e_p50_s):>9} {fmt(m.vllm_e2e_p95_s):>9} │ "
              f"{fmt(m.req_per_s,3):>7} {m.elapsed_s:>6} {m.errors:>5}")
    print()

    # ── Table 5: vLLM Engine ──
    print("═" * 120)
    print("  vLLM INFERENCE ENGINE")
    print("═" * 120)
    print()
    print(f"{'Conc':>5} │ {'TTFT p50':>9} {'TPOT p50':>9} {'KV Cache':>9} {'Running':>8} {'Waiting':>8} {'Out tok/s':>10}")
    print(f"{'':>5} │ {'(ms)':>9} {'(ms)':>9} {'(%)':>9} {'':>8} {'':>8} {'':>10}")
    print("─" * 75)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.vllm_ttft_p50_ms):>9} {fmt(m.vllm_tpot_p50_ms):>9} "
              f"{fmt(m.vllm_kv_cache_pct):>9} {fmt(m.vllm_running,1):>8} "
              f"{fmt(m.vllm_waiting,1):>8} {fmt(m.vllm_out_tok_s,1):>10}")
    print()

    # ── Table 6: GPU ──
    print("═" * 120)
    print("  GPU HARDWARE")
    print("═" * 120)
    print()
    print(f"{'Conc':>5} │ {'GPU Util':>9} {'Power':>8} {'Temp':>7} {'Tensor':>8} {'KV Cache':>9}")
    print(f"{'':>5} │ {'(%)':>9} {'(W)':>8} {'(°C)':>7} {'(%)':>8} {'(%)':>9}")
    print("─" * 60)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.gpu_util_pct,1):>9} {fmt(m.gpu_power_w,1):>8} "
              f"{fmt(m.gpu_temp_c,1):>7} {fmt(m.gpu_tensor_pct,2):>8} {fmt(m.vllm_kv_cache_pct,2):>9}")
    print()

    # ── Table 7: Process Resources ──
    print("═" * 120)
    print("  PROCESS RESOURCE UTILIZATION (per component)")
    print("═" * 120)
    print()
    print(f"{'Conc':>5} │ {'── vLLM ──':>18} │ {'─ Llama Stack ─':>18} │ {'─ PostgreSQL ─':>18} │ {'─ OTel Coll ─':>18}")
    print(f"{'':>5} │ {'CPU':>8} {'MB':>9} │ {'CPU':>8} {'MB':>9} │ {'CPU':>8} {'MB':>9} │ {'CPU':>8} {'MB':>9}")
    print("─" * 95)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.vllm_pod_cpu,3):>8} {fmti(m.vllm_pod_mem_mb):>9} │ "
              f"{fmt(m.ls_pod_cpu,4):>8} {fmti(m.ls_pod_mem_mb):>9} │ "
              f"{fmt(m.pg_pod_cpu,4):>8} {fmti(m.pg_pod_mem_mb):>9} │ "
              f"{fmt(m.otel_pod_cpu,4):>8} {fmti(m.otel_pod_mem_mb):>9}")
    print()

    # ── Table 8: Node Utilization ──
    print("═" * 120)
    print("  INSTANCE (NODE) UTILIZATION BY ROLE")
    print("═" * 120)
    print()
    print(f"{'Conc':>5} │ {'App Worker':>18} │ {'GPU Worker':>18} │ {'Loadgen Worker':>18} │ {'Ctrl Plane':>12}")
    print(f"{'':>5} │ {'CPU%':>8} {'Mem%':>9} │ {'CPU%':>8} {'Mem%':>9} │ {'CPU%':>8} {'Mem%':>9} │ {'CPU%':>12}")
    print("─" * 100)
    for m in results:
        print(f"{m.concurrency:>5} │ {fmt(m.node_app_cpu_pct,1):>8} {fmt(m.node_app_mem_pct,1):>9} │ "
              f"{fmt(m.node_gpu_cpu_pct,1):>8} {fmt(m.node_gpu_mem_pct,1):>9} │ "
              f"{fmt(m.node_loadgen_cpu_pct,1):>8} {fmt(m.node_loadgen_mem_pct,1):>9} │ "
              f"{fmt(m.node_cp_cpu_pct,1):>12}")
    print()

    # ═══════════════════════════════════════════════════════════════════════
    # ANALYSIS
    # ═══════════════════════════════════════════════════════════════════════
    print("═" * 120)
    print("  SCALING ANALYSIS")
    print("═" * 120)

    # Llama Stack overhead
    print("\n── Llama Stack Framework Overhead ──")
    for m in results:
        h = safe(m.ls_http_p50_ms)
        c = safe(m.ls_client_p50_ms)
        if is_valid(h) and is_valid(c) and h > 0:
            oh = h - c
            pct = oh / h * 100
            print(f"    conc={m.concurrency:>3}: overhead={oh:>8.1f}ms ({pct:.1f}% of total)")

    # Llama Stack resource scaling
    print("\n── Llama Stack Resource Scaling ──")
    for attr, label, unit in [
        ("ls_cpu_ratio", "CPU ratio", ""),
        ("ls_threads", "Threads", ""),
        ("ls_fds", "File descriptors", ""),
        ("ls_pod_mem_mb", "Memory", "MB"),
    ]:
        vals = [(m.concurrency, safe(getattr(m, attr))) for m in results]
        valid = [(c, v) for c, v in vals if is_valid(v)]
        if valid:
            base = valid[0][1]
            peak_v = max(v for _, v in valid)
            peak_c = [c for c, v in valid if v == peak_v][0]
            delta = ((peak_v - base) / base * 100) if base > 0 else 0
            print(f"    {label:<20}: {base:.4f} → {peak_v:.4f} (conc={peak_c})  {delta:+.1f}% {unit}")

    # DB pool
    print("\n── Database Connection Pool ──")
    max_used = max((safe(m.ls_db_used) for m in results), default=0)
    max_idle = max((safe(m.ls_db_idle) for m in results), default=0)
    if is_valid(max_used):
        if max_used == 0:
            print(f"    ✓ No contention (max used=0, idle={max_idle:.0f})")
        elif max_used < max_idle * 0.5:
            print(f"    ✓ Healthy (max used={max_used:.0f}, idle={max_idle:.0f})")
        else:
            print(f"    ⚠ Pressure (max used={max_used:.0f}, idle={max_idle:.0f})")

    # Async operations
    print("\n── Async Operations Scaling ──")
    for attr, label in [
        ("ls_async_store_s", "store_chat_completion"),
        ("ls_async_connect_s", "try_connect"),
        ("ls_async_close_s", "close"),
    ]:
        vals = [(m.concurrency, safe(getattr(m, attr))) for m in results]
        valid = [(c, v) for c, v in vals if is_valid(v)]
        if valid:
            base = valid[0][1]
            peak = max(v for _, v in valid)
            print(f"    {label:<25}: {base:.4f}/s → {peak:.4f}/s (peak)")

    # Throughput & saturation
    print("\n── Throughput & Saturation ──")
    prev_rps = None
    sat_conc = None
    deg_conc = None
    for m in results:
        if prev_rps and prev_rps > 0:
            imp = (m.req_per_s - prev_rps) / prev_rps * 100
            if imp < 10 and sat_conc is None and m.concurrency > 2:
                sat_conc = m.concurrency
        prev_rps = m.req_per_s
        w = safe(m.vllm_waiting)
        if is_valid(w) and w > 0 and deg_conc is None:
            deg_conc = m.concurrency

    if len(results) >= 2:
        base_rps = results[0].req_per_s
        peak_rps = max(m.req_per_s for m in results)
        peak_c = [m.concurrency for m in results if m.req_per_s == peak_rps][0]
        print(f"    Base (conc=1): {base_rps:.3f} req/s")
        print(f"    Peak:          {peak_rps:.3f} req/s at concurrency={peak_c}")
        if base_rps > 0:
            print(f"    Speedup:       {peak_rps/base_rps:.1f}x")

        base_e2e = safe(results[0].vllm_e2e_p50_s)
        peak_e2e = safe(results[-1].vllm_e2e_p50_s)
        base_ttft = safe(results[0].vllm_ttft_p50_ms)
        peak_ttft = safe(results[-1].vllm_ttft_p50_ms)
        if is_valid(base_e2e) and is_valid(peak_e2e) and base_e2e > 0:
            print(f"\n    Latency (conc {results[0].concurrency} → {results[-1].concurrency}):")
            print(f"      vLLM E2E: {base_e2e:.2f}s → {peak_e2e:.2f}s  ({(peak_e2e-base_e2e)/base_e2e*100:+.1f}%)")
        if is_valid(base_ttft) and is_valid(peak_ttft) and base_ttft > 0:
            print(f"      TTFT:     {base_ttft:.1f}ms → {peak_ttft:.1f}ms  ({(peak_ttft-base_ttft)/base_ttft*100:+.1f}%)")

    if sat_conc:
        print(f"\n    ⚡ Throughput saturation at concurrency={sat_conc}")
    if deg_conc:
        print(f"    ⚠  Queue pressure at concurrency={deg_conc}")
    else:
        print(f"    ✓  No queue pressure at any level")

    # GPU
    print("\n── GPU ──")
    peak_gpu = max((safe(m.gpu_util_pct) for m in results), default=0)
    peak_kv = max((safe(m.vllm_kv_cache_pct) for m in results), default=0)
    if is_valid(peak_gpu):
        print(f"    Peak utilization: {peak_gpu:.0f}%")
    if is_valid(peak_kv):
        print(f"    Peak KV cache: {peak_kv:.1f}%")

    # Process resource scaling (all components)
    print("\n── Process Resource Scaling (all components) ──")
    components = [
        ("vllm_pod_cpu", "vllm_pod_mem_mb", "vLLM"),
        ("ls_pod_cpu", "ls_pod_mem_mb", "Llama Stack"),
        ("pg_pod_cpu", "pg_pod_mem_mb", "PostgreSQL"),
        ("otel_pod_cpu", "otel_pod_mem_mb", "OTel Collector"),
    ]
    for cpu_attr, mem_attr, name in components:
        cpu_vals = [(m.concurrency, safe(getattr(m, cpu_attr))) for m in results]
        mem_vals = [(m.concurrency, safe(getattr(m, mem_attr))) for m in results]
        vc = [(c, v) for c, v in cpu_vals if is_valid(v)]
        vm = [(c, v) for c, v in mem_vals if is_valid(v)]
        if vc and vm:
            bc, pc = vc[0][1], max(v for _, v in vc)
            bm, pm = vm[0][1], max(v for _, v in vm)
            cd = ((pc - bc) / bc * 100) if bc > 0 else 0
            md = ((pm - bm) / bm * 100) if bm > 0 else 0
            print(f"    {name:<15} CPU: {bc:.3f} → {pc:.3f} ({cd:+.0f}%)  Mem: {bm:.0f} → {pm:.0f} MB ({md:+.0f}%)")

    # Node utilization
    print("\n── Node Utilization ──")
    for cpu_attr, mem_attr, name in [
        ("node_app_cpu_pct", "node_app_mem_pct", "App Worker"),
        ("node_gpu_cpu_pct", "node_gpu_mem_pct", "GPU Worker"),
        ("node_loadgen_cpu_pct", "node_loadgen_mem_pct", "Loadgen Worker"),
    ]:
        cv = [(m.concurrency, safe(getattr(m, cpu_attr))) for m in results]
        mv = [(m.concurrency, safe(getattr(m, mem_attr))) for m in results]
        vc = [v for _, v in cv if is_valid(v)]
        vm = [v for _, v in mv if is_valid(v)]
        if vc:
            status = "OK" if max(vc) < 70 else ("BUSY" if max(vc) < 90 else "SATURATED")
            print(f"    {name:<18} CPU: {vc[0]:.1f}% → {max(vc):.1f}%  "
                  f"Mem: {max(vm):.1f}% peak  [{status}]")

    cp = [safe(m.node_cp_cpu_pct) for m in results]
    vcp = [v for v in cp if is_valid(v)]
    if vcp:
        print(f"    {'Control Plane':<18} CPU: {vcp[0]:.1f}% → {max(vcp):.1f}%")

    print()

    # Save CSV
    fieldnames = [f.name for f in fields(ScaleMetrics)]
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for m in results:
            writer.writerow(asdict(m))


# ─── Standard load test (4-phase) ───────────────────────────────────────────

def run_standard_test(namespace: str, model: str, mode: str, custom_tag: str,
                      grafana: GrafanaAnnotator):
    profiles = {
        "quick":   {"warmup": 2, "batches": 2, "concurrency": 3, "burst": 5,  "tail": 2, "max_tok": 80},
        "heavy":   {"warmup": 5, "batches": 10, "concurrency": 8, "burst": 15, "tail": 5, "max_tok": 300},
        "default": {"warmup": 5, "batches": 6,  "concurrency": 5, "burst": 10, "tail": 5, "max_tok": 200},
    }
    p = profiles[mode]
    total = p["warmup"] + p["batches"] * p["concurrency"] + p["burst"] + p["tail"]
    model_short = model.split("/")[-1]
    run_id = f"run-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    base_tags = ["benchmark", mode, model_short, run_id]
    if custom_tag:
        base_tags.append(custom_tag)

    print(f"\n{'='*60}")
    print(f"  Load Test: {mode} mode ({total} requests)")
    print(f"  Model: {model}")
    print(f"  Max tokens: {p['max_tok']}")
    print(f"  Run ID: {run_id}")
    if custom_tag:
        print(f"  Tag: {custom_tag}")
    print(f"{'='*60}\n")

    run_start = epoch_ms()

    # Phase 1: Warm-up
    grafana.annotate(epoch_ms(), f"Phase 1: Warm-up ({p['warmup']} sequential)", base_tags + ["phase-warmup"])
    info(f"Phase 1: Warm-up ({p['warmup']} sequential)...")
    for i in range(p["warmup"]):
        send_request(namespace, model, PROMPTS_SHORT[i % len(PROMPTS_SHORT)], p["max_tok"])
        print(f"  warm-up {i+1}/{p['warmup']} done")

    # Phase 2: Sustained
    print()
    grafana.annotate(epoch_ms(), f"Phase 2: Sustained ({p['batches']}×{p['concurrency']})", base_tags + ["phase-sustained"])
    info(f"Phase 2: Sustained ({p['batches']} × {p['concurrency']} = {p['batches']*p['concurrency']})...")
    for batch in range(p["batches"]):
        send_batch(namespace, model, p["concurrency"], p["max_tok"], PROMPTS_LONG)
        print(f"  batch {batch+1}/{p['batches']} done")

    # Phase 3: Burst
    print()
    grafana.annotate(epoch_ms(), f"Phase 3: Burst ({p['burst']} concurrent)", base_tags + ["phase-burst"])
    info(f"Phase 3: Burst ({p['burst']} concurrent)...")
    send_batch(namespace, model, p["burst"], p["max_tok"], PROMPTS_LONG)
    print(f"  burst done ({p['burst']} concurrent)")

    # Phase 4: Tail
    print()
    grafana.annotate(epoch_ms(), f"Phase 4: Tail ({p['tail']} sequential)", base_tags + ["phase-tail"])
    info(f"Phase 4: Tail ({p['tail']} sequential)...")
    for i in range(p["tail"]):
        send_request(namespace, model, PROMPTS_SHORT[i % len(PROMPTS_SHORT)], p["max_tok"])
        print(f"  tail {i+1}/{p['tail']} done")

    run_end = epoch_ms()
    elapsed = (run_end - run_start) // 1000

    label = f"{mode} mode"
    if custom_tag:
        label += f" [{custom_tag}]"
    text = f"Load Test: {label}\\n{total} requests in {elapsed}s\\nModel: {model_short}\\nMax tokens: {p['max_tok']}"
    grafana.annotate(run_start, text, base_tags + ["run-region"], run_end)

    print(f"\n{'='*60}")
    ok("Load test complete")
    info(f"  Run ID:         {run_id}")
    info(f"  Total requests: {total}")
    info(f"  Elapsed time:   {elapsed}s")
    info(f"  Avg req time:   {elapsed // total}s")
    if grafana.enabled:
        print()
        ok("  Grafana annotations created")
        info(f"    Tags: {', '.join(base_tags)}")
    if grafana.url:
        print()
        info(f"  {grafana.url}")
    print(f"{'='*60}")


# ─── Scaling test ────────────────────────────────────────────────────────────

def run_scaling_test(namespace: str, model: str, levels: list[int],
                     custom_tag: str, grafana: GrafanaAnnotator,
                     prom: PrometheusClient):
    reqs_per_level = 800
    max_tok = 150
    model_short = model.split("/")[-1]
    run_id = f"scale-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    csv_path = f"/tmp/{run_id}-results.csv"

    print(f"\n╔{'═'*60}╗")
    print(f"║  CONCURRENCY SCALING TEST{' '*35}║")
    print(f"║  Model: {model[:50]:<51}║")
    print(f"║  Levels: {' '.join(str(l) for l in levels):<50}║")
    print(f"║  Requests/level: {reqs_per_level:<42}║")
    print(f"║  Max tokens: {max_tok:<46}║")
    print(f"║  Run ID: {run_id:<50}║")
    print(f"╚{'═'*60}╝\n")

    scale_start = epoch_ms()
    grafana.annotate(scale_start, f"Scaling test: levels {levels}",
                     ["benchmark", "scale", model_short, run_id])

    all_results: list[ScaleMetrics] = []

    for conc in levels:
        print(f"{'━'*60}")
        info(f"Level: concurrency={conc} ({reqs_per_level} requests)")
        print(f"{'━'*60}")

        level_start = epoch_ms()
        grafana.annotate(level_start, f"Scale: concurrency={conc}",
                         ["benchmark", "scale", model_short, run_id, f"conc-{conc}"])

        t0 = time.time()
        errors = 0

        if conc == 1:
            for i in range(reqs_per_level):
                ok_ = send_request(namespace, model,
                                   PROMPTS_LONG[i % len(PROMPTS_LONG)], max_tok)
                if not ok_:
                    errors += 1
                print(".", end="", flush=True)
        else:
            sent = 0
            while sent < reqs_per_level:
                batch = min(conc, reqs_per_level - sent)
                errs = send_batch(namespace, model, batch, max_tok, PROMPTS_LONG)
                errors += errs
                sent += batch
                print(".", end="", flush=True)

        t1 = time.time()
        elapsed = max(int(t1 - t0), 1)
        rps = reqs_per_level / elapsed
        level_end = epoch_ms()

        grafana.annotate(level_start,
                         f"Scale conc={conc}: {reqs_per_level} reqs in {elapsed}s",
                         ["benchmark", "scale", model_short, run_id, f"conc-{conc}", "run-region"],
                         level_end)

        print()
        info(f"  Completed in {elapsed}s ({rps:.3f} req/s)")

        # Wait for Prometheus scrape cycle (15s default) to ingest final samples
        info(f"  Waiting 20s for final scrape before collecting metrics...")
        time.sleep(20)

        metrics = collect_metrics(prom, level_start=t0, level_end=t1)
        metrics.concurrency = conc
        metrics.requests = reqs_per_level
        metrics.elapsed_s = elapsed
        metrics.req_per_s = rps
        metrics.errors = errors
        all_results.append(metrics)

        info(f"  Metrics captured for concurrency={conc}")
        print()

    scale_end = epoch_ms()
    scale_elapsed = (scale_end - scale_start) // 1000
    grafana.annotate(scale_start,
                     f"Scaling test complete: {len(levels)} levels in {scale_elapsed}s",
                     ["benchmark", "scale", model_short, run_id, "run-region"],
                     scale_end)

    print(f"\n╔{'═'*60}╗")
    print(f"║  SCALING TEST RESULTS{' '*39}║")
    print(f"╚{'═'*60}╝")
    print(f"  Metric collection: time-windowed per level (no bleed-over)")
    print(f"  Rate metrics: instant query @ level_end, window = level duration")
    print(f"  Gauge metrics: range query max over [level_start, level_end]")
    print()

    print_scaling_report(all_results, csv_path)

    ok(f"Results saved to {csv_path}")
    info("Grafana annotations created for each level")
    if grafana.url:
        info(f"View at: {grafana.url}")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Load test for Llama Stack on OpenShift")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--quick", action="store_true", help="Quick: 15 requests")
    mode_group.add_argument("--heavy", action="store_true", help="Heavy: 100 requests")
    mode_group.add_argument("--scale", action="store_true", help="Concurrency scaling test")
    parser.add_argument("--levels", nargs="+", type=int, default=[5, 10, 20, 40, 60, 80, 100, 150, 200, 300, 500, 1000],
                        help="Concurrency levels for --scale (default: 5 10 20 40 60 80 100 150 200 300 500 1000)")
    parser.add_argument("--tag", default="", help="Custom annotation tag")
    args = parser.parse_args()

    if args.quick:
        mode = "quick"
    elif args.heavy:
        mode = "heavy"
    elif args.scale:
        mode = "scale"
    else:
        mode = "default"

    # Load config.env if present
    script_dir = Path(__file__).parent
    config_env = script_dir / "config.env"
    namespace = os.environ.get("PERF_NAMESPACE", "perf-testing")
    if config_env.exists():
        result = subprocess.run(
            ["bash", "-c", f"source {config_env} && env"],
            capture_output=True, text=True,
        )
        for line in result.stdout.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                if k == "PERF_NAMESPACE":
                    namespace = v

    # Verify cluster connection
    try:
        oc("whoami")
    except Exception:
        bail("Cannot connect to cluster. Set KUBECONFIG.")

    # Discover model
    info("Discovering model from Llama Stack...")
    resp = oc_exec_curl(namespace, "llama-stack", "http://localhost:8321/v1/models")
    try:
        model = resp["data"][0]["id"]
        ok(f"Discovered model: {model}")
    except (KeyError, IndexError, TypeError):
        bail("Could not discover model. Is Llama Stack running?")

    grafana = GrafanaAnnotator(namespace)

    if mode == "scale":
        prom = PrometheusClient()
        if not prom.connect():
            bail("Cannot reach Prometheus. Scaling test requires metric collection.")
        ok("Connected to Prometheus")
        run_scaling_test(namespace, model, args.levels, args.tag, grafana, prom)
    else:
        run_standard_test(namespace, model, mode, args.tag, grafana)


if __name__ == "__main__":
    main()
