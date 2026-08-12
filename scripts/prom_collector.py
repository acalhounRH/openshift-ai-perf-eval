#!/usr/bin/env python3
"""Prometheus metric collector and Grafana annotator for OGX benchmarks.

Provides:
  - PrometheusClient  — instant, range-avg, range-max, and raw time-series queries
  - GrafanaAnnotator  — push point and region annotations to Grafana
  - Metric definitions for OGX, vLLM, GPU, node, and process metrics
  - collect_aggregates()  — per-window summary (avg/max) of every metric
  - collect_timeseries()  — raw (timestamp, value) time-series for every metric
  - save_prom_data()      — write both to a JSON file suitable as an MLflow artifact

Designed to run inside the benchmark-runner pod where:
  - The ServiceAccount token is mounted at /var/run/secrets/…
  - Prometheus is reachable at thanos-querier.openshift-monitoring.svc:9091
  - Grafana (if deployed) is reachable at grafana.<namespace>.svc:3000
"""

from __future__ import annotations

import base64
import json
import math
import os
import ssl
import time
import urllib.parse
import urllib.request
from typing import Optional

# ─── Constants ────────────────────────────────────────────────────────────────

SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
PROMETHEUS_HOST = "thanos-querier.openshift-monitoring.svc:9091"
DEFAULT_STEP = 15  # seconds between range-query data points


# ─── Prometheus client ────────────────────────────────────────────────────────

class PrometheusClient:
    def __init__(self):
        self.host: Optional[str] = None
        self.token: Optional[str] = None
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE

    def connect(self) -> bool:
        try:
            if not os.path.exists(SA_TOKEN_PATH):
                return False
            with open(SA_TOKEN_PATH, encoding="utf-8") as f:
                self.token = f.read().strip()
            self.host = PROMETHEUS_HOST
            url = f"https://{self.host}/api/v1/query?query=up"
            req = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {self.token}"},
            )
            urllib.request.urlopen(req, context=self._ctx, timeout=10)
            return True
        except Exception:
            self.host = None
            return False

    @property
    def available(self) -> bool:
        return self.host is not None

    def _get(self, url: str) -> dict:
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {self.token}"},
        )
        resp = urllib.request.urlopen(req, context=self._ctx, timeout=30)
        return json.loads(resp.read())

    # ── Instant query ────────────────────────────────────────────────────

    def query(self, promql: str,
              at_time: Optional[float] = None) -> Optional[float]:
        if not self.host:
            return None
        params = {"query": promql}
        if at_time is not None:
            params["time"] = str(at_time)
        url = (f"https://{self.host}/api/v1/query?"
               f"{urllib.parse.urlencode(params)}")
        try:
            data = self._get(url)
            results = data.get("data", {}).get("result", [])
            if results:
                val = float(results[0]["value"][1])
                return val if math.isfinite(val) else None
        except Exception:
            pass
        return None

    # ── Range query — aggregate ──────────────────────────────────────────

    def query_range_avg(self, promql: str, start: float, end: float,
                        step: int = DEFAULT_STEP) -> Optional[float]:
        if not self.host:
            return None
        params = urllib.parse.urlencode({
            "query": promql, "start": str(start),
            "end": str(end), "step": str(step),
        })
        url = f"https://{self.host}/api/v1/query_range?{params}"
        try:
            data = self._get(url)
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
                        step: int = DEFAULT_STEP) -> Optional[float]:
        if not self.host:
            return None
        params = urllib.parse.urlencode({
            "query": promql, "start": str(start),
            "end": str(end), "step": str(step),
        })
        url = f"https://{self.host}/api/v1/query_range?{params}"
        try:
            data = self._get(url)
            results = data.get("data", {}).get("result", [])
            if results:
                values = [float(v[1]) for v in results[0]["values"]
                          if math.isfinite(float(v[1]))]
                if values:
                    return max(values)
        except Exception:
            pass
        return None

    # ── Range query — raw time-series ────────────────────────────────────

    def query_range_series(
        self, promql: str, start: float, end: float,
        step: int = DEFAULT_STEP,
    ) -> list[tuple[float, float]]:
        """Return [(unix_ts, value), …] for a single-series range query."""
        if not self.host:
            return []
        params = urllib.parse.urlencode({
            "query": promql, "start": str(start),
            "end": str(end), "step": str(step),
        })
        url = f"https://{self.host}/api/v1/query_range?{params}"
        try:
            data = self._get(url)
            results = data.get("data", {}).get("result", [])
            if results:
                return [
                    (float(v[0]), float(v[1]))
                    for v in results[0]["values"]
                    if math.isfinite(float(v[1]))
                ]
        except Exception:
            pass
        return []


# ─── Grafana annotator ────────────────────────────────────────────────────────

class GrafanaAnnotator:
    def __init__(self, namespace: str):
        self.enabled = False
        self.url: Optional[str] = None
        user = os.environ.get("GRAFANA_ADMIN_USER", "admin")
        pw = os.environ.get("GRAFANA_ADMIN_PASSWORD", "admin")
        self._auth = (
            "Basic "
            + base64.b64encode(f"{user}:{pw}".encode()).decode()
        )
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE
        try:
            self.url = f"http://grafana.{namespace}.svc:3000"
            req = urllib.request.Request(
                f"{self.url}/api/annotations",
                headers={"Authorization": self._auth},
            )
            resp = urllib.request.urlopen(req, timeout=5)
            if resp.status == 200:
                self.enabled = True
        except Exception:
            pass

    def annotate(self, time_ms: int, text: str, tags: list[str],
                 time_end_ms: Optional[int] = None):
        if not self.enabled:
            return
        body: dict = {"time": time_ms, "tags": tags, "text": text}
        if time_end_ms:
            body["timeEnd"] = time_end_ms
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{self.url}/api/annotations",
            data=data,
            headers={
                "Authorization": self._auth,
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


# ─── Metric definitions ──────────────────────────────────────────────────────

def rate_metrics(ns: str, pg_db: str = "llamastack") -> dict[str, str]:
    """Metrics that require rate() — queried as instant at window end."""
    return {
        # OGX request duration (seconds → ms for display)
        "ogx_req_p50_ms": (
            'histogram_quantile(0.50, sum(rate('
            'ogx_request_duration_seconds_bucket'
            '{{service_name="ogx"}}[{window}])) by (le)) * 1000'
        ),
        "ogx_req_p95_ms": (
            'histogram_quantile(0.95, sum(rate('
            'ogx_request_duration_seconds_bucket'
            '{{service_name="ogx"}}[{window}])) by (le)) * 1000'
        ),
        "ogx_req_p99_ms": (
            'histogram_quantile(0.99, sum(rate('
            'ogx_request_duration_seconds_bucket'
            '{{service_name="ogx"}}[{window}])) by (le)) * 1000'
        ),
        # OGX inference duration (backend latency, seconds → ms)
        "ogx_inf_p50_ms": (
            'histogram_quantile(0.50, sum(rate('
            'ogx_inference_duration_seconds_bucket'
            '{{service_name="ogx"}}[{window}])) by (le)) * 1000'
        ),
        "ogx_inf_p95_ms": (
            'histogram_quantile(0.95, sum(rate('
            'ogx_inference_duration_seconds_bucket'
            '{{service_name="ogx"}}[{window}])) by (le)) * 1000'
        ),
        # OGX request rate
        "ogx_rps": (
            'sum(rate(ogx_requests_total'
            '{{service_name="ogx"}}[{window}]))'
        ),
        # OGX inference tokens/s
        "ogx_tok_p50_s": (
            'histogram_quantile(0.50, sum(rate('
            'ogx_inference_tokens_per_second_bucket'
            '{{service_name="ogx"}}[{window}])) by (le))'
        ),
        "ogx_tok_p95_s": (
            'histogram_quantile(0.95, sum(rate('
            'ogx_inference_tokens_per_second_bucket'
            '{{service_name="ogx"}}[{window}])) by (le))'
        ),
        # vLLM engine
        "vllm_ttft_p50_ms": (
            'histogram_quantile(0.50, sum(rate('
            'vllm:time_to_first_token_seconds_bucket'
            '[{window}])) by (le)) * 1000'
        ),
        "vllm_tpot_p50_ms": (
            'histogram_quantile(0.50, sum(rate('
            'vllm:time_per_output_token_seconds_bucket'
            '[{window}])) by (le)) * 1000'
        ),
        "vllm_e2e_p50_s": (
            'histogram_quantile(0.50, sum(rate('
            'vllm:e2e_request_latency_seconds_bucket'
            '[{window}])) by (le))'
        ),
        "vllm_e2e_p95_s": (
            'histogram_quantile(0.95, sum(rate('
            'vllm:e2e_request_latency_seconds_bucket'
            '[{window}])) by (le))'
        ),
        "vllm_out_tok_s": (
            'sum(rate(vllm:generation_tokens_total[{window}]))'
        ),
        # Process CPU (rate-based, cores)
        "vllm_pod_cpu": (
            f'sum(rate(container_cpu_usage_seconds_total'
            f'{{{{namespace="{ns}",pod=~"vllm.*",'
            f'container!="",container!="POD"}}}}[{{window}}]))'
        ),
        "ogx_pod_cpu": (
            f'sum(rate(container_cpu_usage_seconds_total'
            f'{{{{namespace="{ns}",pod=~"ogx.*",'
            f'container!="",container!="POD"}}}}[{{window}}]))'
        ),
        "pg_pod_cpu": (
            f'sum(rate(container_cpu_usage_seconds_total'
            f'{{{{namespace="{ns}",pod=~"postgresql.*",'
            f'container!="",container!="POD"}}}}[{{window}}]))'
        ),
        "otel_pod_cpu": (
            f'sum(rate(container_cpu_usage_seconds_total'
            f'{{{{namespace="{ns}",pod=~"otel.*",'
            f'container!="",container!="POD"}}}}[{{window}}]))'
        ),
        # Network I/O (bytes/s)
        "ogx_net_rx_bps": (
            f'sum(rate(container_network_receive_bytes_total'
            f'{{{{namespace="{ns}",pod=~"ogx.*"}}}}[{{window}}]))'
        ),
        "ogx_net_tx_bps": (
            f'sum(rate(container_network_transmit_bytes_total'
            f'{{{{namespace="{ns}",pod=~"ogx.*"}}}}[{{window}}]))'
        ),
        "pg_net_rx_bps": (
            f'sum(rate(container_network_receive_bytes_total'
            f'{{{{namespace="{ns}",pod=~"postgresql.*"}}}}[{{window}}]))'
        ),
        "pg_net_tx_bps": (
            f'sum(rate(container_network_transmit_bytes_total'
            f'{{{{namespace="{ns}",pod=~"postgresql.*"}}}}[{{window}}]))'
        ),
        "vllm_net_rx_bps": (
            f'sum(rate(container_network_receive_bytes_total'
            f'{{{{namespace="{ns}",pod=~"vllm.*"}}}}[{{window}}]))'
        ),
        "vllm_net_tx_bps": (
            f'sum(rate(container_network_transmit_bytes_total'
            f'{{{{namespace="{ns}",pod=~"vllm.*"}}}}[{{window}}]))'
        ),
        # Node CPU (rate-based)
        "node_ogx_cpu_pct": (
            '100 * avg(1 - rate(node_cpu_seconds_total'
            '{{mode="idle"}}[{window}]) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{{label_node_role_kubernetes_io_ogx_worker=""}},'
            '"instance","$1","node","(.+)"))'
        ),
        "node_postgres_cpu_pct": (
            '100 * avg(1 - rate(node_cpu_seconds_total'
            '{{mode="idle"}}[{window}]) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{{label_node_role_kubernetes_io_postgres_worker=""}},'
            '"instance","$1","node","(.+)"))'
        ),
        "node_loadgen_cpu_pct": (
            '100 * avg(1 - rate(node_cpu_seconds_total'
            '{{mode="idle"}}[{window}]) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{{label_node_role_kubernetes_io_loadgen_worker=""}},'
            '"instance","$1","node","(.+)"))'
        ),
        "node_cp_cpu_pct": (
            '100 * avg(1 - rate(node_cpu_seconds_total'
            '{{mode="idle"}}[{window}]) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{{label_node_role_kubernetes_io_master=""}},'
            '"instance","$1","node","(.+)"))'
        ),
        # PostgreSQL exporter rates
        "pg_xact_commit_rate": (
            f'sum(rate(pg_stat_database_xact_commit'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_xact_rollback_rate": (
            f'sum(rate(pg_stat_database_xact_rollback'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_tup_fetched_rate": (
            f'sum(rate(pg_stat_database_tup_fetched'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_tup_inserted_rate": (
            f'sum(rate(pg_stat_database_tup_inserted'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_tup_updated_rate": (
            f'sum(rate(pg_stat_database_tup_updated'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_blks_hit_rate": (
            f'sum(rate(pg_stat_database_blks_hit'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
        "pg_blks_read_rate": (
            f'sum(rate(pg_stat_database_blks_read'
            f'{{{{namespace="{ns}",datname="{pg_db}"}}}}[{{window}}]))'
        ),
    }


def gauge_metrics(ns: str) -> dict[str, str]:
    """Point-in-time gauges — queried as range max over the window."""
    return {
        # OGX gauges
        "ogx_concurrent_reqs": (
            'ogx_concurrent_requests'
            '{service_name="ogx"}'
        ),
        # vLLM gauges
        "vllm_kv_cache_pct": 'vllm:gpu_cache_usage_perc * 100',
        "vllm_running": 'vllm:num_requests_running',
        "vllm_waiting": 'vllm:num_requests_waiting',
        # GPU gauges
        "gpu_util_pct": 'avg(DCGM_FI_DEV_GPU_UTIL)',
        "gpu_power_w": 'avg(DCGM_FI_DEV_POWER_USAGE)',
        "gpu_temp_c": 'avg(DCGM_FI_DEV_GPU_TEMP)',
        "gpu_tensor_pct": (
            'avg(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE) * 100'
        ),
        # Memory gauges
        "vllm_pod_mem_mb": (
            f'sum(container_memory_working_set_bytes'
            f'{{namespace="{ns}",pod=~"vllm.*",'
            f'container!=""}}) / 1048576'
        ),
        "ogx_pod_mem_mb": (
            f'sum(container_memory_working_set_bytes'
            f'{{namespace="{ns}",pod=~"ogx.*",'
            f'container!="",container!="POD"}}) / 1048576'
        ),
        "pg_pod_mem_mb": (
            f'sum(container_memory_working_set_bytes'
            f'{{namespace="{ns}",pod=~"postgresql.*",'
            f'container!=""}}) / 1048576'
        ),
        "otel_pod_mem_mb": (
            f'sum(container_memory_working_set_bytes'
            f'{{namespace="{ns}",pod=~"otel.*",'
            f'container!=""}}) / 1048576'
        ),
        # Node memory gauges
        "node_ogx_mem_pct": (
            '100 * avg(1 - (node_memory_MemAvailable_bytes '
            '/ node_memory_MemTotal_bytes) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_ogx_worker=""},'
            '"instance","$1","node","(.+)"))'
        ),
        "node_postgres_mem_pct": (
            '100 * avg(1 - (node_memory_MemAvailable_bytes '
            '/ node_memory_MemTotal_bytes) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_postgres_worker=""},'
            '"instance","$1","node","(.+)"))'
        ),
        "node_loadgen_mem_pct": (
            '100 * avg(1 - (node_memory_MemAvailable_bytes '
            '/ node_memory_MemTotal_bytes) * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_loadgen_worker=""},'
            '"instance","$1","node","(.+)"))'
        ),
        # PostgreSQL exporter gauges
        "pg_connections_active": (
            f'sum(pg_stat_activity_count'
            f'{{namespace="{ns}",datname="llamastack"}})'
        ),
        "pg_database_size_mb": (
            f'pg_database_size_bytes'
            f'{{namespace="{ns}",datname="llamastack"}} / 1048576'
        ),
        "pg_locks_total": (
            f'sum(pg_locks_count'
            f'{{namespace="{ns}",datname="llamastack"}})'
        ),
        "pg_deadlocks": (
            f'pg_stat_database_deadlocks'
            f'{{namespace="{ns}",datname="llamastack"}}'
        ),
        "pg_max_connections": (
            f'pg_settings_max_connections'
            f'{{namespace="{ns}"}}'
        ),
        "pg_cache_hit_ratio": (
            f'pg_stat_database_blks_hit{{namespace="{ns}",datname="llamastack"}}'
            f' / (pg_stat_database_blks_hit{{namespace="{ns}",datname="llamastack"}}'
            f' + pg_stat_database_blks_read{{namespace="{ns}",datname="llamastack"}}'
            f' + 0.001) * 100'
        ),
        # Storage (PVC usage, MB)
        "pg_storage_used_mb": (
            f'kubelet_volume_stats_used_bytes'
            f'{{namespace="{ns}",'
            f'persistentvolumeclaim="postgresql-data"}}'
            f' / 1048576'
        ),
        "pg_storage_cap_mb": (
            f'kubelet_volume_stats_capacity_bytes'
            f'{{namespace="{ns}",'
            f'persistentvolumeclaim="postgresql-data"}}'
            f' / 1048576'
        ),
    }


# ─── High-level collectors ────────────────────────────────────────────────────

def collect_aggregates(
    prom: PrometheusClient,
    start: float, end: float,
    namespace: str = "perf-testing",
) -> dict[str, Optional[float]]:
    """Collect aggregate values for all metrics over [start, end].

    Rate metrics are evaluated via instant query at ``end`` with a rate
    window equal to the test duration.  Gauge metrics use a range query
    returning the max over the window.
    """
    agg: dict[str, Optional[float]] = {}
    duration_s = max(int(end - start), 15)
    window = f"{max(duration_s, 120)}s"

    for key, tpl in rate_metrics(namespace).items():
        query = tpl.format(window=window)
        agg[key] = prom.query(query, at_time=end)

    for key, query in gauge_metrics(namespace).items():
        agg[key] = prom.query_range_max(query, start, end)

    return agg


def collect_timeseries(
    prom: PrometheusClient,
    start: float, end: float,
    namespace: str = "perf-testing",
    step: int = DEFAULT_STEP,
) -> dict[str, list[tuple[float, float]]]:
    """Collect raw time-series for every metric over [start, end].

    Rate metrics are wrapped so the range query window matches the
    scrape interval.  Gauges are queried directly.
    """
    series: dict[str, list[tuple[float, float]]] = {}
    window = f"{max(step * 4, 120)}s"

    for key, tpl in rate_metrics(namespace).items():
        query = tpl.format(window=window)
        pts = prom.query_range_series(query, start, end, step)
        if pts:
            series[key] = pts

    for key, query in gauge_metrics(namespace).items():
        pts = prom.query_range_series(query, start, end, step)
        if pts:
            series[key] = pts

    return series


# ─── Full raw dump ────────────────────────────────────────────────────────────

def _discover_series(
    prom: PrometheusClient,
    matchers: list[str],
    start: float, end: float,
) -> list[str]:
    """Return unique metric names matching any of the given label matchers."""
    names: set[str] = set()
    if not prom.host:
        return []
    for match in matchers:
        params = urllib.parse.urlencode({
            "match[]": match, "start": str(start), "end": str(end),
        })
        url = f"https://{prom.host}/api/v1/series?{params}"
        try:
            data = prom._get(url)
            for series in data.get("data", []):
                name = series.get("__name__", "")
                if name:
                    names.add(name)
        except Exception:
            pass
    return sorted(names)


def collect_raw_dump(
    prom: PrometheusClient,
    start: float, end: float,
    namespace: str = "perf-testing",
    step: int = DEFAULT_STEP,
) -> dict:
    """Dump ALL Prometheus time-series for the namespace and related app
    metrics during [start, end].  Returns a dict keyed by a label
    signature with raw (timestamp, value) arrays.

    Broad matchers cover:
      - All container/kubelet metrics for the namespace
      - All OGX application metrics (ogx_*)
      - All vLLM metrics (vllm:*, vllm_*)
      - Node-level metrics for worker nodes
    """
    if not prom.host:
        return {}

    broad_matchers = [
        f'{{namespace="{namespace}"}}',
        '{__name__=~"ogx_.*"}',
        '{__name__=~"vllm:.*|vllm_.*"}',
        f'{{__name__=~"pg_.*",namespace="{namespace}"}}',
    ]

    raw: dict[str, list[list]] = {}
    total_series = 0

    for matcher in broad_matchers:
        params = urllib.parse.urlencode({
            "query": matcher,
            "start": str(start), "end": str(end), "step": str(step),
        })
        url = f"https://{prom.host}/api/v1/query_range?{params}"
        try:
            data = prom._get(url)
            for result in data.get("data", {}).get("result", []):
                metric = result.get("metric", {})
                label_sig = _label_signature(metric)
                values = [
                    [round(float(v[0]), 1), _safe_float(v[1])]
                    for v in result.get("values", [])
                ]
                if values:
                    raw[label_sig] = values
                    total_series += 1
        except Exception:
            pass

    # Node metrics for labeled workers (not namespace-scoped)
    node_matchers = [
        (
            'node_cpu_seconds_total{mode="idle"} * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_ogx_worker=""},'
            '"instance","$1","node","(.+)")'
        ),
        (
            'node_memory_MemAvailable_bytes * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_ogx_worker=""},'
            '"instance","$1","node","(.+)")'
        ),
        (
            'node_memory_MemTotal_bytes * on(instance) '
            'group_left() label_replace(kube_node_labels'
            '{label_node_role_kubernetes_io_ogx_worker=""},'
            '"instance","$1","node","(.+)")'
        ),
    ]
    for query in node_matchers:
        params = urllib.parse.urlencode({
            "query": query,
            "start": str(start), "end": str(end), "step": str(step),
        })
        url = f"https://{prom.host}/api/v1/query_range?{params}"
        try:
            data = prom._get(url)
            for result in data.get("data", {}).get("result", []):
                metric = result.get("metric", {})
                label_sig = _label_signature(metric)
                values = [
                    [round(float(v[0]), 1), _safe_float(v[1])]
                    for v in result.get("values", [])
                ]
                if values:
                    raw[label_sig] = values
                    total_series += 1
        except Exception:
            pass

    return raw


def _label_signature(metric: dict) -> str:
    """Build a unique string key from the full label set."""
    name = metric.get("__name__", "unnamed")
    labels = {k: v for k, v in sorted(metric.items()) if k != "__name__"}
    if labels:
        label_str = ",".join(f'{k}="{v}"' for k, v in labels.items())
        return f"{name}{{{label_str}}}"
    return name


def _safe_float(v) -> float:
    try:
        f = float(v)
        return f if math.isfinite(f) else 0.0
    except (ValueError, TypeError):
        return 0.0


def save_raw_dump(
    output_path: str,
    start: float, end: float,
    raw: dict,
    metadata: Optional[dict] = None,
) -> None:
    """Write the raw Prometheus dump to a JSON file."""
    doc = {
        "metadata": metadata or {},
        "window": {
            "start_unix": start,
            "end_unix": end,
            "duration_s": round(end - start, 1),
        },
        "series_count": len(raw),
        "series": raw,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(doc, f)


# ─── Persistence ──────────────────────────────────────────────────────────────

def save_prom_data(
    output_path: str,
    start: float,
    end: float,
    aggregates: dict[str, Optional[float]],
    timeseries: dict[str, list[tuple[float, float]]],
    metadata: Optional[dict] = None,
) -> None:
    """Write collected Prometheus data to a JSON file.

    Structure:
      {
        "metadata": { … },
        "window": { "start_unix": …, "end_unix": …, "duration_s": … },
        "aggregates": { "metric_name": value, … },
        "timeseries": {
          "metric_name": [[unix_ts, value], …],
          …
        }
      }
    """
    doc = {
        "metadata": metadata or {},
        "window": {
            "start_unix": start,
            "end_unix": end,
            "duration_s": round(end - start, 1),
        },
        "aggregates": {
            k: round(v, 6) if v is not None else None
            for k, v in aggregates.items()
        },
        "timeseries": {
            k: [[round(t, 1), round(v, 6)] for t, v in pts]
            for k, pts in timeseries.items()
        },
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
