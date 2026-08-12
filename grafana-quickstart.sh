#!/usr/bin/env bash
# ============================================================================
# grafana-quickstart.sh — Deploy standalone Grafana with OCP, GPU, LLM,
#                          OGX, and Responses API evaluation dashboards
#
# STANDALONE: This script is self-contained. It can run on any OpenShift
# cluster with an AI inference stack (vLLM + OGX). If config.env
# exists alongside this script, it will be sourced for PERF_NAMESPACE and
# helper functions. Otherwise, standalone defaults are used.
#
# Prerequisites (auto-detected and created if missing):
#   - User workload monitoring enabled
#   - ServiceMonitors for vLLM, OTel Collector, DCGM exporter
#   - OTel Collector for OGX metrics
#
# Usage:
#   bash ./grafana-quickstart.sh                         # deploy (default ns: perf-testing)
#   PERF_NAMESPACE=my-ns bash ./grafana-quickstart.sh    # deploy to custom namespace
#   bash ./grafana-quickstart.sh teardown                # remove everything
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config.env if available; otherwise define standalone defaults
if [[ -f "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}" ]]; then
  source "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}"
else
  export PERF_NAMESPACE="${PERF_NAMESPACE:-perf-testing}"
  info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
  ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
  warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
  err()   { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
  bail()  { err "$*"; exit 1; }
fi

GRAFANA_NS="${PERF_NAMESPACE}"
GRAFANA_SA="grafana"

ALL_DASHBOARD_CMS="grafana-datasources grafana-dashboards grafana-dashboard-ocp grafana-dashboard-gpu grafana-dashboard-llm grafana-dashboard-perf-eval grafana-dashboard-llamastack grafana-dashboard-responses-api grafana-dashboard-traces grafana-dashboard-perf-eng grafana-dashboard-instance-resources grafana-dashboard-ai-gateway"

# ─── Teardown mode ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  info "Tearing down Grafana..."
  oc delete route grafana -n "${GRAFANA_NS}" 2>/dev/null || true
  oc delete service grafana -n "${GRAFANA_NS}" 2>/dev/null || true
  oc delete deployment grafana -n "${GRAFANA_NS}" 2>/dev/null || true
  oc delete configmap ${ALL_DASHBOARD_CMS} -n "${GRAFANA_NS}" 2>/dev/null || true
  oc delete sa "${GRAFANA_SA}" -n "${GRAFANA_NS}" 2>/dev/null || true
  oc delete clusterrolebinding grafana-cluster-monitoring-view 2>/dev/null || true
  ok "Grafana removed from ${GRAFANA_NS}"
  exit 0
fi

echo ""
echo "============================================"
echo "  Deploying Grafana"
echo "  Namespace: ${GRAFANA_NS}"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 0. PREREQUISITES — ensure monitoring pipeline is in place
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Checking prerequisites..."

oc get namespace "${GRAFANA_NS}" >/dev/null 2>&1 || \
  { info "Creating namespace ${GRAFANA_NS}..."; oc create namespace "${GRAFANA_NS}"; }

# User workload monitoring — required for Prometheus to scrape ServiceMonitors in user namespaces
UWM_ENABLED=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableUserWorkload: true" || echo "0")
if [[ "$UWM_ENABLED" -eq 0 ]]; then
  warn "User workload monitoring is not enabled. Enabling it now..."
  oc apply -f - <<'UWMEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
UWMEOF
  ok "User workload monitoring enabled (Prometheus will start scraping user namespaces)"
  info "Waiting 30s for monitoring stack to reconcile..."
  sleep 30
else
  ok "User workload monitoring already enabled"
fi

# vLLM ServiceMonitor — scrapes vLLM's native /metrics endpoint
if ! oc get servicemonitor vllm-inference-metrics -n "${GRAFANA_NS}" >/dev/null 2>&1; then
  info "Creating vLLM ServiceMonitor..."
  oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-inference-metrics
  namespace: ${GRAFANA_NS}
  labels:
    app: vllm-inference
spec:
  endpoints:
  - path: /metrics
    port: http
    interval: 15s
  selector:
    matchLabels:
      app: vllm-inference
EOF
  ok "vLLM ServiceMonitor created"
else
  ok "vLLM ServiceMonitor already exists"
fi

# OTel Collector ServiceMonitor — scrapes OGX metrics converted to Prometheus format
if ! oc get servicemonitor otel-collector-metrics -n "${GRAFANA_NS}" >/dev/null 2>&1; then
  info "Creating OTel Collector ServiceMonitor..."
  oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-metrics
  namespace: ${GRAFANA_NS}
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  endpoints:
  - port: prometheus
    interval: 30s
    path: /metrics
  selector:
    matchLabels:
      app.kubernetes.io/component: opentelemetry-collector
EOF
  ok "OTel Collector ServiceMonitor created"
else
  ok "OTel Collector ServiceMonitor already exists"
fi

# DCGM exporter ServiceMonitor — scrapes GPU metrics
if ! oc get servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator >/dev/null 2>&1; then
  if oc get namespace nvidia-gpu-operator >/dev/null 2>&1; then
    info "Creating DCGM exporter ServiceMonitor..."
    oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nvidia-dcgm-exporter
  namespace: nvidia-gpu-operator
  labels:
    app: nvidia-dcgm-exporter
spec:
  endpoints:
  - path: /metrics
    port: gpu-metrics
    interval: 15s
  namespaceSelector:
    matchNames:
    - nvidia-gpu-operator
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
EOF
    ok "DCGM exporter ServiceMonitor created"
  else
    warn "nvidia-gpu-operator namespace not found — GPU dashboard panels will be empty"
  fi
else
  ok "DCGM exporter ServiceMonitor already exists"
fi

# Payload Processing ServiceMonitor — scrapes BBR plugin metrics
if ! oc get servicemonitor payload-processing-metrics -n openshift-ingress >/dev/null 2>&1; then
  info "Creating Payload Processing ServiceMonitor..."
  oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payload-processing-metrics
  namespace: openshift-ingress
  labels:
    app: payload-processing
spec:
  endpoints:
  - port: metrics
    path: /metrics
    interval: 15s
  selector:
    matchLabels:
      app.kubernetes.io/name: payload-processing
EOF
  ok "Payload Processing ServiceMonitor created"
else
  ok "Payload Processing ServiceMonitor already exists"
fi

# MaaS Gateway PodMonitor — scrapes Envoy/Istio metrics from the gateway proxy
if ! oc get podmonitor maas-gateway-envoy-metrics -n openshift-ingress >/dev/null 2>&1; then
  info "Creating MaaS Gateway Envoy PodMonitor..."
  oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: maas-gateway-envoy-metrics
  namespace: openshift-ingress
  labels:
    app: maas-gateway
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  podMetricsEndpoints:
  - port: metrics
    path: /stats/prometheus
    interval: 15s
EOF
  ok "MaaS Gateway Envoy PodMonitor created"
else
  ok "MaaS Gateway Envoy PodMonitor already exists"
fi

ok "Prerequisites verified"
echo ""

# Helper: apply a ConfigMap heredoc with namespace injection
apply_cm() {
  sed -e "s/GRAFANA_NS_PLACEHOLDER/${GRAFANA_NS}/g" \
      -e "s/namespace=\\\\\"perf-testing\\\\\"/namespace=\\\\\"${GRAFANA_NS}\\\\\"/g" \
      -e "s/namespace=\\\"perf-testing\\\"/namespace=\\\"${GRAFANA_NS}\\\"/g" \
      -e "s/(perf-testing)/(${GRAFANA_NS})/g" \
      -e "s/Pod Status (perf-testing)/Pod Status (${GRAFANA_NS})/g" \
      -e "s/Pod CPU (perf-testing)/Pod CPU (${GRAFANA_NS})/g" \
      -e "s/Pod Memory (perf-testing)/Pod Memory (${GRAFANA_NS})/g" \
      -e "s/Pod CPU (perf-testing namespace)/Pod CPU (${GRAFANA_NS})/g" \
      -e "s/Pod Memory (perf-testing namespace)/Pod Memory (${GRAFANA_NS})/g" \
    | oc apply -f -
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. SERVICE ACCOUNT WITH MONITORING ACCESS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating Grafana ServiceAccount with cluster-monitoring-view..."

oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${GRAFANA_SA}
  namespace: ${GRAFANA_NS}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.grafana: '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"grafana"}}'
EOF

oc adm policy add-cluster-role-to-user cluster-monitoring-view -z "${GRAFANA_SA}" -n "${GRAFANA_NS}"

# Get a long-lived token for the datasource
GRAFANA_TOKEN=$(oc create token "${GRAFANA_SA}" -n "${GRAFANA_NS}" --duration=8760h 2>/dev/null || \
  oc sa get-token "${GRAFANA_SA}" -n "${GRAFANA_NS}" 2>/dev/null || echo "")
if [[ -z "$GRAFANA_TOKEN" ]]; then
  bail "Could not obtain a ServiceAccount token for Grafana"
fi
ok "ServiceAccount token obtained"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. DATASOURCE CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating datasource ConfigMap..."

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: ${GRAFANA_NS}
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: OpenShift Prometheus
      type: prometheus
      access: proxy
      url: https://thanos-querier.openshift-monitoring.svc:9091
      isDefault: true
      uid: prometheus
      jsonData:
        tlsSkipVerify: true
        httpHeaderName1: Authorization
      secureJsonData:
        httpHeaderValue1: "Bearer ${GRAFANA_TOKEN}"
EOF

ok "Datasources configured (Prometheus)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. DASHBOARD PROVIDER CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: ${GRAFANA_NS}
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
    - name: default
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards
        foldersFromFilesStructure: false
EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. OCP CLUSTER OVERVIEW DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating dashboards..."

apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-ocp
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  ocp-cluster-overview.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "title": "Cluster CPU Usage",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) by (instance)",
              "legendFormat": "{{instance}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "Cluster Memory Usage",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes",
              "legendFormat": "{{instance}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        },
        {
          "title": "Pod Count by Namespace",
          "type": "bargauge",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "count(kube_pod_info) by (namespace)",
              "legendFormat": "{{namespace}}"
            }
          ],
          "fieldConfig": { "defaults": { "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":50},{"color":"red","value":100}] } }, "overrides": [] },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "Pod Status (perf-testing)",
          "type": "table",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "kube_pod_status_phase{namespace=\"perf-testing\"} == 1",
              "legendFormat": "{{pod}} — {{phase}}",
              "format": "table",
              "instant": true
            }
          ],
          "transformations": [
            { "id": "organize", "options": { "excludeByName": { "Time": true, "Value": true, "__name__": true, "endpoint": true, "instance": true, "job": true, "service": true, "uid": true, "container": true, "prometheus": true }, "renameByName": { "pod": "Pod", "phase": "Phase", "namespace": "Namespace" } } }
          ]
        },
        {
          "title": "Node CPU by Role",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) by (instance) / count(node_cpu_seconds_total{mode=\"idle\"}) by (instance) * 100",
              "legendFormat": "{{instance}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "max": 100 }, "overrides": [] }
        },
        {
          "title": "Network I/O (all nodes)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(node_network_receive_bytes_total{device!~\"lo|veth.*|br.*\"}[5m]))",
              "legendFormat": "Receive"
            },
            {
              "expr": "sum(rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|br.*\"}[5m]))",
              "legendFormat": "Transmit"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] }
        },
        {
          "title": "Disk I/O",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 24 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(node_disk_read_bytes_total[5m])) by (instance)",
              "legendFormat": "{{instance}} read"
            },
            {
              "expr": "sum(rate(node_disk_written_bytes_total[5m])) by (instance)",
              "legendFormat": "{{instance}} write"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "OCP Cluster Overview",
      "uid": "ocp-cluster-overview"
    }
CONFIGMAP_EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. GPU / DCGM DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-gpu
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  gpu-metrics.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "panels": [
        {
          "title": "GPU Utilization (%)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "DCGM_FI_DEV_GPU_UTIL",
              "legendFormat": "GPU {{gpu}} ({{UUID}})"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] }
        },
        {
          "title": "GPU Memory Used (GiB)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "DCGM_FI_DEV_FB_USED / 1024",
              "legendFormat": "GPU {{gpu}} used"
            },
            {
              "expr": "DCGM_FI_DEV_FB_FREE / 1024",
              "legendFormat": "GPU {{gpu}} free"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "gibibytes" }, "overrides": [] }
        },
        {
          "title": "GPU Temperature (°C)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "DCGM_FI_DEV_GPU_TEMP",
              "legendFormat": "GPU {{gpu}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "celsius", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":75},{"color":"red","value":90}] } }, "overrides": [] }
        },
        {
          "title": "GPU Power Usage (W)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "DCGM_FI_DEV_POWER_USAGE",
              "legendFormat": "GPU {{gpu}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "watt" }, "overrides": [] }
        },
        {
          "title": "GPU SM Clock (MHz)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "DCGM_FI_DEV_SM_CLOCK",
              "legendFormat": "GPU {{gpu}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "clockhertz" }, "overrides": [] }
        },
        {
          "title": "GPU PCIe TX/RX Throughput",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "rate(DCGM_FI_PROF_PCIE_TX_BYTES[1m])",
              "legendFormat": "GPU {{gpu}} TX"
            },
            {
              "expr": "rate(DCGM_FI_PROF_PCIE_RX_BYTES[1m])",
              "legendFormat": "GPU {{gpu}} RX"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "KBs" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "GPU Metrics (DCGM)",
      "uid": "gpu-dcgm-metrics"
    }
CONFIGMAP_EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. LLM INFERENCE DASHBOARD (vLLM + OGX)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-llm
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  llm-inference.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "panels": [
        {
          "title": "vLLM — Requests/sec",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(vllm:request_success_total[1m]))",
              "legendFormat": "success/s"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "vLLM — Request Latency (p50, p95, p99)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))",
              "legendFormat": "p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))",
              "legendFormat": "p95"
            },
            {
              "expr": "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))",
              "legendFormat": "p99"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — Running / Waiting / Swapped Requests",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "vllm:num_requests_running",
              "legendFormat": "running"
            },
            {
              "expr": "vllm:num_requests_waiting",
              "legendFormat": "waiting"
            },
            {
              "expr": "vllm:num_requests_swapped",
              "legendFormat": "swapped"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "vLLM — GPU KV Cache Usage (%)",
          "type": "gauge",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "vllm:gpu_cache_usage_perc * 100",
              "legendFormat": "KV cache"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}] } }, "overrides": [] }
        },
        {
          "title": "vLLM — Tokens Generated/sec",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(vllm:generation_tokens_total[1m]))",
              "legendFormat": "generation tokens/s"
            },
            {
              "expr": "sum(rate(vllm:prompt_tokens_total[1m]))",
              "legendFormat": "prompt tokens/s"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "vLLM — Time to First Token (TTFT)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))",
              "legendFormat": "p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))",
              "legendFormat": "p95"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — Time per Output Token (TPOT)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))",
              "legendFormat": "p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))",
              "legendFormat": "p95"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "OGX — HTTP Latency (OTel)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 24 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le)) * 1000",
              "legendFormat": "p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le)) * 1000",
              "legendFormat": "p95"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "vLLM — Prefill vs Decode Time",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 32 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:request_prefill_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "prefill p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:request_prefill_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "prefill p95"
            },
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:request_decode_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "decode p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:request_decode_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "decode p95"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — Queue Wait Time & Prefix Cache Hit Rate",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 32 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "histogram_quantile(0.50, sum(rate(vllm:request_queue_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "queue wait p50"
            },
            {
              "expr": "histogram_quantile(0.95, sum(rate(vllm:request_queue_time_seconds_bucket[5m])) by (le))",
              "legendFormat": "queue wait p95"
            },
            {
              "expr": "vllm:gpu_prefix_cache_hit_rate * 100",
              "legendFormat": "prefix cache hit %"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{ "matcher": { "id": "byName", "options": "prefix cache hit %" }, "properties": [{ "id": "unit", "value": "percent" }] }] }
        },
        {
          "title": "OGX — HTTP Request Rate by Endpoint",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 40 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target!=\"\"}[5m])) by (http_target)",
              "legendFormat": "{{http_target}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "OGX — Active Requests & Error Rate",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 40 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "ogx_concurrent_requests{service_name=\"ogx\"}",
              "legendFormat": "active HTTP requests"
            },
            {
              "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_status_code!~\"2..\"}[5m]))",
              "legendFormat": "errors/s (non-2xx)"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "Pod CPU (perf-testing)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 48 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",container!=\"\"}[5m])) by (pod)",
              "legendFormat": "{{pod}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "Pod Memory (perf-testing)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 48 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",container!=\"\"}) by (pod)",
              "legendFormat": "{{pod}}"
            }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "LLM Inference (vLLM + OGX)",
      "uid": "llm-inference"
    }
CONFIGMAP_EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6b. PERFORMANCE EVALUATION DASHBOARD (AI Stack → GPU → Per-Instance)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-perf-eval
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  perf-evaluation.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "graphTooltip": 1,
      "panels": [
        {
          "title": "── AI STACK ──────────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "collapsed": false
        },
        {
          "title": "vLLM — Requests/sec",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:request_success_total[1m]))", "legendFormat": "success/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "vLLM — E2E Latency (p50/p95/p99)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — GPU KV Cache Usage",
          "type": "gauge",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "vllm:gpu_cache_usage_perc * 100", "legendFormat": "KV cache %" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}] } }, "overrides": [] }
        },
        {
          "title": "vLLM — TTFT (Time to First Token)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — TPOT (Time per Output Token)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM — Token Throughput",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 8 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "generation tok/s" },
            { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "prompt tok/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "vLLM — Queue Depth",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "vllm:num_requests_running", "legendFormat": "running" },
            { "expr": "vllm:num_requests_waiting", "legendFormat": "waiting" },
            { "expr": "vllm:num_requests_swapped", "legendFormat": "swapped" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — HTTP Server Latency (OTel)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le)) * 1000", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le)) * 1000", "legendFormat": "p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "OGX — Token Throughput & Request Rate",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output tok/s" },
            { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input tok/s" },
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m]))", "legendFormat": "OGX requests/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "── GPU ───────────────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 22 },
          "collapsed": false
        },
        {
          "title": "GPU Utilization (%)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_GPU_UTIL", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] }
        },
        {
          "title": "GPU Memory (GiB)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_FB_USED / 1024", "legendFormat": "GPU {{gpu}} used" },
            { "expr": "DCGM_FI_DEV_FB_FREE / 1024", "legendFormat": "GPU {{gpu}} free" }
          ],
          "fieldConfig": { "defaults": { "unit": "gibibytes" }, "overrides": [] }
        },
        {
          "title": "GPU Temperature (°C)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_GPU_TEMP", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "celsius", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":75},{"color":"red","value":90}] } }, "overrides": [] }
        },
        {
          "title": "GPU Power (W)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 30 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_POWER_USAGE", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "watt" }, "overrides": [] }
        },
        {
          "title": "Tensor Core Activity",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 30 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "percentunit", "min": 0, "max": 1 }, "overrides": [] }
        },
        {
          "title": "GPU PCIe Throughput",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 30 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "rate(DCGM_FI_PROF_PCIE_TX_BYTES[1m])", "legendFormat": "GPU {{gpu}} TX" },
            { "expr": "rate(DCGM_FI_PROF_PCIE_RX_BYTES[1m])", "legendFormat": "GPU {{gpu}} RX" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] }
        },
        {
          "title": "── PER-INSTANCE ──────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 37 },
          "collapsed": false
        },
        {
          "title": "Node CPU Usage (%)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 38 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) by (instance))", "legendFormat": "{{instance}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] }
        },
        {
          "title": "Node Memory Usage",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 38 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "legendFormat": "{{instance}} used" }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        },
        {
          "title": "Node Network I/O",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 45 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(node_network_receive_bytes_total{device!~\"lo|veth.*|br.*\"}[5m])) by (instance)", "legendFormat": "{{instance}} RX" },
            { "expr": "sum(rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|br.*\"}[5m])) by (instance)", "legendFormat": "{{instance}} TX" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] }
        },
        {
          "title": "Node Disk I/O",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 45 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(node_disk_read_bytes_total[5m])) by (instance)", "legendFormat": "{{instance}} read" },
            { "expr": "sum(rate(node_disk_written_bytes_total[5m])) by (instance)", "legendFormat": "{{instance}} write" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "Performance Evaluation",
      "uid": "perf-evaluation"
    }
CONFIGMAP_EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6c. LLAMA STACK DEEP-DIVE DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-llamastack
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  llamastack-deep-dive.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "graphTooltip": 1,
      "panels": [
        {
          "title": "── GENAI INFERENCE ───────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "collapsed": false
        },
        {
          "title": "OGX — HTTP Server Latency (p50 / p95 / p99)",
          "description": "End-to-end HTTP latency of OGX API endpoints (includes vLLM inference round-trip)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "OGX — Token Throughput (vLLM engine)",
          "description": "Rate of tokens processed at the vLLM engine level — prompt (input) and generation (output)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input (prompt) tok/s" },
            { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output (generation) tok/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — Avg Tokens per Request",
          "description": "Average prompt and generation tokens per vLLM request — computed from vLLM token counters and request success rate",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:prompt_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg input tokens" },
            { "expr": "sum(rate(vllm:generation_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg output tokens" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — API Request Rate",
          "description": "HTTP request rate by endpoint — chat completions, responses, health",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 9 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target!=\"\"}[5m])) by (http_target)", "legendFormat": "{{http_target}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "OGX — Avg API Latency",
          "description": "Average HTTP server latency across inference endpoints (simpler view for trending)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 9 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_sum{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) / sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) * 1000", "legendFormat": "avg latency" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "── HTTP API SERVER ──────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 17 },
          "collapsed": false
        },
        {
          "title": "OGX — API Request Rate by Endpoint",
          "description": "HTTP requests/sec broken down by API endpoint",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",service=\"otel-collector-collector\",http_target!=\"\"}[5m])) by (http_target)", "legendFormat": "{{http_target}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "OGX — API Latency by Endpoint (p95)",
          "description": "95th percentile HTTP server latency for each OGX endpoint",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",service=\"otel-collector-collector\",http_target=~\"/v1/chat/completions|/v1/models|/v1/health\"}[5m])) by (le, http_target)) * 1000", "legendFormat": "{{http_target}} p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "OGX — Active Requests & Error Rate",
          "description": "In-flight HTTP requests and non-2xx responses per second",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "ogx_concurrent_requests{service_name=\"ogx\",service=\"otel-collector-collector\"}", "legendFormat": "active requests" },
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",service=\"otel-collector-collector\",http_status_code!~\"2..\"}[5m]))", "legendFormat": "errors/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — Request & Response Sizes (p95)",
          "description": "95th percentile HTTP request and response body sizes",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 26 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p95" },
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p50" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "vLLM — Engine Latency (p50 / p95)",
          "description": "vLLM inference engine end-to-end latency — measures the raw model serving time",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 26 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" }, "overrides": [] }
        },
        {
          "title": "── DATABASE ─────────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 34 },
          "collapsed": false
        },
        {
          "title": "PostgreSQL — Container CPU & Memory",
          "description": "Container-level resource usage for PostgreSQL pods in the perf-testing namespace",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU (cores)" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}) by (pod) / 1024 / 1024", "legendFormat": "{{pod}} mem (MiB)" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "PostgreSQL — Async DB Coroutine Rate",
          "description": "Rate of key database-touching async operations from OGX — store_chat_completion, try_connect, close",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "ops" }, "overrides": [] }
        },
        {
          "title": "── PROCESS HEALTH ───────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 42 },
          "collapsed": false
        },
        {
          "title": "OGX — Container CPU Usage",
          "description": "CPU cores consumed by OGX containers — sustained high usage indicates the API layer is CPU-bound",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "min": 0 }, "overrides": [] }
        },
        {
          "title": "OGX — Container Memory",
          "description": "Working set memory of OGX containers — watch for growth over time (memory leaks)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}) by (pod)", "legendFormat": "{{pod}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        },
        {
          "title": "OGX — Container Restarts & Throttling",
          "description": "Container restart count and CFS throttling — sustained throttling indicates CPU limits too low",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"perf-testing\",pod=~\"ogx.*\"}) by (pod)", "legendFormat": "{{pod}} restarts" },
            { "expr": "sum(rate(container_cpu_cfs_throttled_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) / sum(rate(container_cpu_cfs_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) * 100", "legendFormat": "CPU throttle %" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — OTel Spans Created",
          "description": "Rate of OTel spans started — indicates the tracing activity level of the OGX process",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 50 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" },
            { "expr": "ogx_concurrent_requests{service_name=\"ogx\"}", "legendFormat": "concurrent requests" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "vLLM — Container CPU & Memory",
          "description": "vLLM inference server container resource usage — CPU should be low; memory includes model weights",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 50 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"vllm.*\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU (cores)" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"vllm.*\",container!=\"\"}) by (pod) / 1024 / 1024 / 1024", "legendFormat": "{{pod}} mem (GiB)" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "── PYTHON RUNTIME ───────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 57 },
          "collapsed": false
        },
        {
          "title": "OGX — Asyncio Coroutine Rate",
          "description": "Rate of asyncio coroutines created (key async operations in OGX)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 58 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "ops" }, "overrides": [] }
        },
        {
          "title": "OGX — Asyncio Coroutine Duration (p50 / p95)",
          "description": "Latency of key async operations — store_chat_completion, inference calls, DB connections",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 58 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(asyncio_process_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le, name))", "legendFormat": "{{name}} p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(asyncio_process_duration_seconds_bucket{service_name=\"ogx\"}[5m])) by (le, name))", "legendFormat": "{{name}} p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "OGX Deep Dive",
      "uid": "llamastack-deep-dive"
    }
CONFIGMAP_EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6d. RESPONSES API EVALUATION DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-responses-api
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  responses-api-eval.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "graphTooltip": 2,
      "panels": [
        {
          "title": "── RESPONSES API LATENCY ─────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "collapsed": false
        },
        {
          "title": "OGX — End-to-End Response Latency (p50 / p95 / p99)",
          "description": "Total time from Responses API request to complete response — HTTP server-side latency including vLLM inference, DB writes, and tool orchestration",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms", "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10 } }, "overrides": [] }
        },
        {
          "title": "OGX — Latency Breakdown vs vLLM Inference",
          "description": "Decomposes total API latency into vLLM inference time and OGX processing overhead. Overhead = total HTTP server − vLLM e2e.",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_sum{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) / sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) * 1000", "legendFormat": "total API avg (ms)" },
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p50 (ms)" },
            { "expr": "(sum(rate(ogx_request_duration_seconds_sum{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) / sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m]))) * 1000 - (histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000)", "legendFormat": "OGX overhead (ms)" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms", "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10 } }, "overrides": [{ "matcher": { "id": "byName", "options": "OGX overhead (ms)" }, "properties": [{ "id": "custom.lineStyle", "value": { "fill": "dash" } }, { "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] }] }
        },
        {
          "title": "vLLM Time to First Token (TTFT)",
          "description": "How quickly the model starts generating — critical for streaming UX and perceived responsiveness",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 9 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM Time per Output Token (TPOT)",
          "description": "Inter-token latency — determines streaming speed and effective generation throughput",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 9 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM Queue Wait Time",
          "description": "Time requests spend waiting in vLLM's scheduler queue before processing begins",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 9 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:request_queue_time_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:request_queue_time_seconds_bucket[5m])) by (le))", "legendFormat": "p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "── THROUGHPUT & TOKENS ───────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 17 },
          "collapsed": false
        },
        {
          "title": "OGX — Request Rate",
          "description": "Responses API requests per second — overall throughput capacity",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m]))", "legendFormat": "requests/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
        },
        {
          "title": "OGX — Token Throughput (vLLM engine)",
          "description": "Token processing rate at vLLM engine level — prompt (input) and generation (output) tokens per second",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input (prompt) tok/s" },
            { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output (gen) tok/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — Avg Tokens per Request",
          "description": "Average prompt and generation tokens per request — computed from vLLM token counters and request success rate",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 18 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:prompt_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg input tokens" },
            { "expr": "sum(rate(vllm:generation_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg output tokens" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — API Request/Response Payload Sizes (p95)",
          "description": "95th percentile HTTP body sizes — useful for capacity planning and network bandwidth evaluation",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 26 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p95" },
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p50" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "OGX — Error Rate & Active Requests",
          "description": "Non-2xx error rate and concurrent in-flight requests — key for reliability and saturation assessment",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 26 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "ogx_concurrent_requests{service_name=\"ogx\",service=\"otel-collector-collector\"}", "legendFormat": "active requests" },
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",service=\"otel-collector-collector\",http_status_code!~\"2..\"}[5m]))", "legendFormat": "errors/s (non-2xx)" },
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",service=\"otel-collector-collector\",http_status_code=~\"2..\"}[5m]))", "legendFormat": "success/s (2xx)" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{ "matcher": { "id": "byName", "options": "errors/s (non-2xx)" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }] }
        },
        {
          "title": "── VLLM ENGINE ──────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 34 },
          "collapsed": false
        },
        {
          "title": "vLLM Request Latency (p50 / p95 / p99)",
          "description": "Raw vLLM inference latency — no OGX overhead. Compare with end-to-end to isolate bottlenecks.",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM Scheduler Queue Depth",
          "description": "Running / waiting / swapped requests in vLLM — rising 'waiting' indicates GPU saturation",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "vllm:num_requests_running", "legendFormat": "running" },
            { "expr": "vllm:num_requests_waiting", "legendFormat": "waiting" },
            { "expr": "vllm:num_requests_swapped", "legendFormat": "swapped" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{ "matcher": { "id": "byName", "options": "waiting" }, "properties": [{ "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "swapped" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }] }
        },
        {
          "title": "GPU KV Cache Usage (%)",
          "description": "Percentage of GPU memory used for KV cache — approaching 100% causes request queueing and preemption",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "vllm:gpu_cache_usage_perc * 100", "legendFormat": "KV cache %" },
            { "expr": "vllm:gpu_prefix_cache_hit_rate * 100", "legendFormat": "prefix cache hit %" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}] }, "custom": { "fillOpacity": 15 } }, "overrides": [] }
        },
        {
          "title": "vLLM Prefill vs Decode Time",
          "description": "Prefill (prompt processing) vs decode (token generation) time — shows whether the workload is input-heavy or output-heavy",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:request_prefill_time_seconds_bucket[5m])) by (le))", "legendFormat": "prefill p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:request_prefill_time_seconds_bucket[5m])) by (le))", "legendFormat": "prefill p95" },
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:request_decode_time_seconds_bucket[5m])) by (le))", "legendFormat": "decode p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:request_decode_time_seconds_bucket[5m])) by (le))", "legendFormat": "decode p95" }
          ],
          "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
        },
        {
          "title": "vLLM Success Rate",
          "description": "Successful inference completions per second at the engine level",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(vllm:request_success_total[1m]))", "legendFormat": "success/s" },
            { "expr": "sum(rate(vllm:num_preemptions_total[1m]))", "legendFormat": "preemptions/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [{ "matcher": { "id": "byName", "options": "preemptions/s" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }] }
        },
        {
          "title": "── GPU PERFORMANCE ──────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 51 },
          "collapsed": false
        },
        {
          "title": "GPU Utilization (%)",
          "description": "SM utilization per GPU — shows how much compute capacity is being used during inference",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 52 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_GPU_UTIL", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] }
        },
        {
          "title": "GPU Memory (Used / Free GiB)",
          "description": "GPU framebuffer usage — used includes model weights + KV cache + activations",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 52 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_FB_USED / 1024", "legendFormat": "GPU {{gpu}} used" },
            { "expr": "DCGM_FI_DEV_FB_FREE / 1024", "legendFormat": "GPU {{gpu}} free" }
          ],
          "fieldConfig": { "defaults": { "unit": "gibibytes" }, "overrides": [] }
        },
        {
          "title": "Tensor Core Activity & DRAM Activity",
          "description": "Tensor core utilization (matrix ops) and memory bandwidth utilization — low tensor + high DRAM = memory-bound",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 52 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE * 100", "legendFormat": "GPU {{gpu}} tensor %" },
            { "expr": "DCGM_FI_PROF_DRAM_ACTIVE * 100", "legendFormat": "GPU {{gpu}} DRAM %" }
          ],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] }
        },
        {
          "title": "GPU Power Draw (W)",
          "description": "Power consumption per GPU — proxy for compute intensity and thermal headroom",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 60 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_POWER_USAGE", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "watt" }, "overrides": [] }
        },
        {
          "title": "GPU Temperature (°C)",
          "description": "GPU die temperature — thermal throttling begins at ~83°C on A100 / ~90°C on A10G",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 60 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "DCGM_FI_DEV_GPU_TEMP", "legendFormat": "GPU {{gpu}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "celsius", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":75},{"color":"red","value":90}] } }, "overrides": [] }
        },
        {
          "title": "── DATABASE (POSTGRESQL) ────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 67 },
          "collapsed": false
        },
        {
          "title": "PostgreSQL — Container Resources",
          "description": "PostgreSQL pod CPU and memory usage — high CPU or memory pressure indicates DB bottleneck",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU (cores)" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}) by (pod) / 1024 / 1024", "legendFormat": "{{pod}} mem (MiB)" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "custom": { "fillOpacity": 15 } }, "overrides": [] }
        },
        {
          "title": "PostgreSQL — Pod Restarts",
          "description": "PostgreSQL container restart count — any restarts indicate stability issues",
          "type": "stat",
          "gridPos": { "h": 8, "w": 6, "x": 12, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"perf-testing\",pod=~\"postgresql.*\"})", "legendFormat": "restarts" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":1},{"color":"red","value":3}] } }, "overrides": [] }
        },
        {
          "title": "OGX — Async DB Coroutine Rate",
          "description": "Rate of key database-touching async operations — store_chat_completion writes conversation state per response",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 6, "x": 18, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" },
            { "expr": "ogx_concurrent_requests{service_name=\"ogx\"}", "legendFormat": "concurrent requests" }
          ],
          "fieldConfig": { "defaults": { "unit": "ops" }, "overrides": [] }
        },
        {
          "title": "── RESOURCE UTILIZATION ──────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 76 },
          "collapsed": false
        },
        {
          "title": "OGX — Container CPU",
          "description": "CPU cores consumed by OGX containers — should stay low; sustained high usage indicates API layer is CPU-bound",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 0, "y": 77 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}} (cores)" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "min": 0 }, "overrides": [] }
        },
        {
          "title": "OGX — Container Memory",
          "description": "Working set memory — watch for growth over time (memory leaks under sustained load)",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 8, "y": 77 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}) by (pod)", "legendFormat": "{{pod}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        },
        {
          "title": "OGX — Container Restarts & CPU Throttling",
          "description": "Container restarts and CFS throttle percentage — sustained throttling means CPU limits are too low",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 8, "x": 16, "y": 77 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"perf-testing\",pod=~\"ogx.*\"}) by (pod)", "legendFormat": "{{pod}} restarts" },
            { "expr": "sum(rate(container_cpu_cfs_throttled_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) / sum(rate(container_cpu_cfs_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) * 100", "legendFormat": "CPU throttle %" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "Pod CPU (perf-testing namespace)",
          "description": "Container-level CPU usage for all stack components — identifies which pod consumes the most compute",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 84 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] }
        },
        {
          "title": "Pod Memory (perf-testing namespace)",
          "description": "Working set memory for all stack components — identifies memory pressure across the deployment",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 84 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",container!=\"\"}) by (pod)", "legendFormat": "{{pod}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "Responses API Evaluation",
      "uid": "responses-api-eval"
    }
CONFIGMAP_EOF

# ── 10. Distributed Traces Dashboard ──────────────────────────────────────
apply_cm - <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-traces
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  traces.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "graphTooltip": 2,
      "panels": [
        {
          "title": "── TRACE SEARCH ─────────────────────────────",
          "type": "text",
          "gridPos": { "h": 2, "w": 24, "x": 0, "y": 0 },
          "options": { "mode": "markdown", "content": "Search and explore distributed traces from **OGX** and **vLLM**. Traces are collected via the **OTel Collector** and exposed as Prometheus metrics." }
        },
        {
          "title": "OTel Span Rate by Service",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 2 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "ogx requests/s" },
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name!=\"\"}[5m])) by (service_name)", "legendFormat": "{{service_name}} req/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "ops" } }
        },
        {
          "title": "OGX vs vLLM Latency (p50 / p95)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 2 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "OGX HTTP server p50 (ms)" },
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "OGX HTTP server p95 (ms)" },
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p50 (ms)" },
            { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p95 (ms)" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" } }
        },
        {
          "title": "── HOW TO EXPLORE TRACES ─────────────────────",
          "type": "text",
          "gridPos": { "h": 6, "w": 24, "x": 0, "y": 10 },
          "options": { "mode": "markdown", "content": "### OGX Metrics in Grafana\\n\\nMetrics are collected by the **OTel Collector** and exported to Prometheus.\\n\\n**Key Prometheus metrics:**\\n- `ogx_request_duration_seconds` — OGX request latency\\n- `ogx_inference_duration_seconds` — OGX inference backend latency\\n- `ogx_requests_total` — OGX request count\\n- `ogx_concurrent_requests` — Active concurrent requests\\n- `ogx_inference_tokens_per_second` — Token throughput\\n\\n**Tips:**\\n- Use the OGX Deep Dive dashboard for per-operation metrics\\n- Filter by `service_name=\\\"ogx\\\"` for OGX metrics\\n- Compare `ogx_request_duration_seconds` vs `vllm:e2e_request_latency_seconds` to measure orchestration overhead" }
        },
        {
          "title": "OGX HTTP Latency vs vLLM Engine Latency (overhead)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "OGX HTTP server p50 (ms)" },
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "vLLM e2e p50 (ms)" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" } }
        },
        {
          "title": "Request Rate by Endpoint",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target!=\"\"}[5m])) by (http_target)", "legendFormat": "{{http_target}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" } }
        },
        {
          "title": "Token Throughput (vLLM engine)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input (prompt) tok/s" },
            { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output (gen) tok/s" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" } }
        },
        {
          "title": "Async Operations & OTel Spans",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 24 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" },
            { "expr": "ogx_concurrent_requests{service_name=\"ogx\"}", "legendFormat": "concurrent requests" },
            { "expr": "sum(rate(vllm:request_success_total[5m]))", "legendFormat": "vLLM success/s" }
          ]
        }
      ],
      "schemaVersion": 39,
      "templating": { "list": [] },
      "time": { "from": "now-1h", "to": "now" },
      "title": "Distributed Traces",
      "uid": "distributed-traces"
    }
CONFIGMAP_EOF

# ── 11. Agentic Performance Engineering Dashboard ─────────────────────────
apply_cm - <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-perf-eng
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  perf-eng.json: |
    {
      "annotations": { "list": [{ "builtIn": 1, "datasource": { "type": "grafana", "uid": "-- Grafana --" }, "enable": true, "hide": false, "iconColor": "rgba(255, 96, 96, 1)", "name": "Benchmarks", "type": "dashboard", "filter": { "exclude": false, "ids": [], "tags": ["benchmark"] } }] },
      "editable": true,
      "graphTooltip": 2,
      "panels": [
        {
          "title": "── RUN OVERVIEW ──────────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "collapsed": false
        },
        {
          "title": "Request Rate",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 0, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m]))", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":5},{"color":"red","value":20}] } } }
        },
        {
          "title": "Avg Latency",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 4, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "unit": "ms", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":2000},{"color":"red","value":5000}] } } }
        },
        {
          "title": "Error Rate",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 8, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_status_code!~\"2..\"}[5m])) or vector(0)", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":0.1},{"color":"red","value":1}] } } }
        },
        {
          "title": "Active Requests",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 12, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "ogx_concurrent_requests{service_name=\"ogx\"}", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":10},{"color":"red","value":25}] } } }
        },
        {
          "title": "Token Throughput",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 16, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "unit": "short", "displayName": "output tok/s", "thresholds": { "steps": [{"color":"blue","value":null}] } } }
        },
        {
          "title": "GPU Utilization",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 20, "y": 1 },
          "datasource": { "uid": "prometheus" },
          "targets": [{ "expr": "avg(DCGM_FI_DEV_GPU_UTIL)", "legendFormat": "" }],
          "fieldConfig": { "defaults": { "unit": "percent", "thresholds": { "steps": [{"color":"green","value":null},{"color":"yellow","value":80},{"color":"red","value":95}] } } }
        },
        {
          "title": "── REQUEST PIPELINE (Latency Breakdown) ─────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 5 },
          "collapsed": false
        },
        {
          "title": "End-to-End Latency (p50 / p95 / p99)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 6 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" } }
        },
        {
          "title": "Latency Breakdown: OGX Overhead vs Inference",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 8, "y": 6 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "total (HTTP server p50)" },
            { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "inference (vLLM e2e p50)" },
            { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000 - histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "overhead (OGX processing)" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms" } }
        },
        {
          "title": "Request Rate by Endpoint",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 6 },
          "datasource": { "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\",http_target!=\"\"}[5m])) by (http_target)", "legendFormat": "{{http_target}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps" } }
        },
        {
          "title": "── INFERENCE ENGINE (vLLM) ──────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 14 },
          "collapsed": true,
          "panels": [
            {
              "title": "TTFT — Time to First Token",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 15 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
                { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" }
              ],
              "fieldConfig": { "defaults": { "unit": "s" } }
            },
            {
              "title": "TPOT — Time per Output Token",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 15 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.50, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
                { "expr": "histogram_quantile(0.95, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))", "legendFormat": "p95" }
              ],
              "fieldConfig": { "defaults": { "unit": "s" } }
            },
            {
              "title": "KV Cache Usage & Queue Depth",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 15 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "vllm:gpu_cache_usage_perc * 100", "legendFormat": "KV cache %" },
                { "expr": "vllm:num_requests_running", "legendFormat": "running" },
                { "expr": "vllm:num_requests_waiting", "legendFormat": "waiting" }
              ],
              "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{"matcher":{"id":"byName","options":"KV cache %"},"properties":[{"id":"unit","value":"percent"}]}] }
            },
            {
              "title": "Token Throughput (generation vs prompt)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 23 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output tok/s" },
                { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input tok/s" }
              ],
              "fieldConfig": { "defaults": { "unit": "short" } }
            },
            {
              "title": "E2E Request Latency (vLLM internal)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 23 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p50" },
                { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p95" },
                { "expr": "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "p99" }
              ],
              "fieldConfig": { "defaults": { "unit": "s" } }
            },
            {
              "title": "vLLM Request Success Rate",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 23 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(vllm:request_success_total[1m]))", "legendFormat": "success/s" }
              ],
              "fieldConfig": { "defaults": { "unit": "reqps" } }
            }
          ]
        },
        {
          "title": "── TOKEN ECONOMICS ──────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 15 },
          "collapsed": true,
          "panels": [
            {
              "title": "Token Usage Rate (input vs output)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 16 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(vllm:prompt_tokens_total[1m]))", "legendFormat": "input (prompt) tok/s" },
                { "expr": "sum(rate(vllm:generation_tokens_total[1m]))", "legendFormat": "output (gen) tok/s" }
              ],
              "fieldConfig": { "defaults": { "unit": "short" } }
            },
            {
              "title": "Avg Tokens per Request",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 16 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(vllm:prompt_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg input" },
                { "expr": "sum(rate(vllm:generation_tokens_total[5m])) / sum(rate(vllm:request_success_total[5m]))", "legendFormat": "avg output" }
              ]
            },
            {
              "title": "OGX API Latency (p50/p95/p99)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 16 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.50, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p50" },
                { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p95" },
                { "expr": "histogram_quantile(0.99, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target=~\"/v1/chat.*|/v1/responses.*\"}[5m])) by (le)) * 1000", "legendFormat": "p99" }
              ],
              "fieldConfig": { "defaults": { "unit": "ms" } }
            }
          ]
        },
        {
          "title": "── AGENTIC WORKFLOW ─────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 16 },
          "collapsed": true,
          "panels": [
            {
              "title": "Async Operations by Type",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 17 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" }
              ],
              "fieldConfig": { "defaults": { "unit": "ops" } }
            },
            {
              "title": "Request/Response Payload Size (p95)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 17 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.95, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p95" },
                { "expr": "histogram_quantile(0.50, sum(rate(ogx_inference_tokens_per_second_bucket{service_name=\"ogx\"}[5m])) by (le))", "legendFormat": "tokens/s p50" }
              ],
              "fieldConfig": { "defaults": { "unit": "short" } }
            },
            {
              "title": "HTTP Status Codes",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 17 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(ogx_request_duration_seconds_count{service_name=\"ogx\"}[5m])) by (http_status_code)", "legendFormat": "{{http_status_code}}" }
              ],
              "fieldConfig": { "defaults": { "unit": "reqps" } }
            },
            {
              "title": "── Future: Tool Call Metrics",
              "type": "text",
              "gridPos": { "h": 4, "w": 24, "x": 0, "y": 25 },
              "options": { "mode": "markdown", "content": "**Agent tool call metrics will appear here** when OGX exposes them via OTel.\\nExpected metrics: tool call count by type, tool execution latency, multi-turn depth, routing decisions.\\n\\nMonitor `ogx_requests_total{service_name=\\\"ogx\\\"}` for request activity signals." }
            }
          ]
        },
        {
          "title": "── DATA LAYER ──────────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 17 },
          "collapsed": true,
          "panels": [
            {
              "title": "PostgreSQL Container Resources",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 18 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}[5m]))", "legendFormat": "CPU (cores)" },
                { "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",pod=~\"postgresql.*\",container!=\"\"}) / 1024 / 1024", "legendFormat": "mem (MiB)" }
              ]
            },
            {
              "title": "DB Async Operations Rate",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 18 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" }
              ],
              "fieldConfig": { "defaults": { "unit": "ops" } }
            },
            {
              "title": "── Future: Document Ingestion + Vector Store",
              "type": "text",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 18 },
              "options": { "mode": "markdown", "content": "**Document Ingestion** metrics will appear here:\\n- Docs processed/s, avg chunk size\\n- Embedding generation latency\\n- Pipeline throughput (bytes/s)\\n\\n**Vector Store** metrics:\\n- Query latency (p50/p95)\\n- Index size, vector count\\n- Recall / retrieval quality\\n\\nThese will be populated when ingestion\\nand vector_io components emit OTel\\nmetrics to the collector." }
            }
          ]
        },
        {
          "title": "── SERVICE CONNECTIVITY ─────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 18 },
          "collapsed": true,
          "panels": [
            {
              "title": "vLLM Engine Latency (inference time)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 19 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "p50" },
                { "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le)) * 1000", "legendFormat": "p95" }
              ],
              "fieldConfig": { "defaults": { "unit": "ms" } }
            },
            {
              "title": "Endpoint Latency by Route (p95)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 19 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "histogram_quantile(0.95, sum(rate(ogx_request_duration_seconds_bucket{service_name=\"ogx\",http_target!=\"\"}[5m])) by (le, http_target)) * 1000", "legendFormat": "{{http_target}}" }
              ],
              "fieldConfig": { "defaults": { "unit": "ms" } }
            },
            {
              "title": "── Future: MCP Gateway",
              "type": "text",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 19 },
              "options": { "mode": "markdown", "content": "**MCP Gateway** metrics will appear here:\\n- Request routing latency\\n- Protocol translation overhead\\n- Upstream/downstream connection count\\n- Message throughput by tool type\\n- Error rate by MCP server\\n\\nWhen the MCP gateway emits OTel metrics,\\nadd ServiceMonitor and queries here.\\n\\nExpected labels: `mcp_server`, `tool_name`,\\n`mcp_method`" }
            }
          ]
        },
        {
          "title": "── GPU PERFORMANCE ─────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 19 },
          "collapsed": true,
          "panels": [
            {
              "title": "GPU Utilization (%)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 6, "x": 0, "y": 20 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "DCGM_FI_DEV_GPU_UTIL", "legendFormat": "GPU {{gpu}}" }],
              "fieldConfig": { "defaults": { "unit": "percent", "max": 100 } }
            },
            {
              "title": "GPU Memory (GiB)",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 6, "x": 6, "y": 20 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "DCGM_FI_DEV_FB_USED / 1024", "legendFormat": "GPU {{gpu}} used" },
                { "expr": "DCGM_FI_DEV_FB_FREE / 1024", "legendFormat": "GPU {{gpu}} free" }
              ],
              "fieldConfig": { "defaults": { "unit": "gibibytes" } }
            },
            {
              "title": "Tensor Core Activity",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 6, "x": 12, "y": 20 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE", "legendFormat": "GPU {{gpu}}" }],
              "fieldConfig": { "defaults": { "unit": "percentunit" } }
            },
            {
              "title": "Power & Temperature",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 6, "x": 18, "y": 20 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "DCGM_FI_DEV_POWER_USAGE", "legendFormat": "GPU {{gpu}} power (W)" },
                { "expr": "DCGM_FI_DEV_GPU_TEMP", "legendFormat": "GPU {{gpu}} temp (°C)" }
              ]
            },
            {
              "title": "PCIe Throughput",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 12, "x": 0, "y": 28 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "rate(DCGM_FI_PROF_PCIE_TX_BYTES[1m])", "legendFormat": "GPU {{gpu}} TX" },
                { "expr": "rate(DCGM_FI_PROF_PCIE_RX_BYTES[1m])", "legendFormat": "GPU {{gpu}} RX" }
              ],
              "fieldConfig": { "defaults": { "unit": "Bps" } }
            },
            {
              "title": "GPU SM Clock",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 12, "x": 12, "y": 28 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "DCGM_FI_DEV_SM_CLOCK", "legendFormat": "GPU {{gpu}}" }],
              "fieldConfig": { "defaults": { "unit": "clockhertz" } }
            }
          ]
        },
        {
          "title": "── RESOURCE UTILIZATION ─────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 20 },
          "collapsed": true,
          "panels": [
            {
              "title": "Pod CPU Usage",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 0, "y": 21 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",container!=\"\"}[5m])) by (pod)", "legendFormat": "{{pod}}" }],
              "fieldConfig": { "defaults": { "unit": "short", "displayName": "cores" } }
            },
            {
              "title": "Pod Memory Usage",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 8, "y": 21 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "sum(container_memory_working_set_bytes{namespace=\"perf-testing\",container!=\"\"}) by (pod)", "legendFormat": "{{pod}}" }],
              "fieldConfig": { "defaults": { "unit": "bytes" } }
            },
            {
              "title": "OGX Container Health",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 8, "x": 16, "y": 21 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m]))", "legendFormat": "CPU (cores)" },
                { "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"perf-testing\",pod=~\"ogx.*\"})", "legendFormat": "restarts" },
                { "expr": "sum(rate(container_cpu_cfs_throttled_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) / sum(rate(container_cpu_cfs_periods_total{namespace=\"perf-testing\",pod=~\"ogx.*\",container!=\"\"}[5m])) * 100", "legendFormat": "CPU throttle %" }
              ]
            },
            {
              "title": "Node CPU Utilization",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 12, "x": 0, "y": 29 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) by (instance))", "legendFormat": "{{instance}}" }],
              "fieldConfig": { "defaults": { "unit": "percent" } }
            },
            {
              "title": "Node Memory Usage",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 12, "x": 12, "y": 29 },
              "datasource": { "uid": "prometheus" },
              "targets": [{ "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "legendFormat": "{{instance}}" }],
              "fieldConfig": { "defaults": { "unit": "bytes" } }
            }
          ]
        },
        {
          "title": "── TRACES & DIAGNOSTICS ─────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 21 },
          "collapsed": true,
          "panels": [
            {
              "title": "Trace Exploration Guide",
              "type": "text",
              "gridPos": { "h": 8, "w": 12, "x": 0, "y": 22 },
              "options": { "mode": "markdown", "content": "### OGX Metrics (OTel → Prometheus)\\n\\nOGX-native metrics are available via Prometheus:\\n\\n| Metric | What It Shows |\\n|---|---|\\n| `ogx_request_duration_seconds` | OGX request latency |\\n| `ogx_inference_duration_seconds` | Inference backend latency |\\n| `ogx_requests_total` | Request count |\\n| `ogx_concurrent_requests` | Active concurrent requests |\\n| `ogx_inference_tokens_per_second` | Token throughput |\\n\\nOGX overhead = OGX request time − vLLM e2e time" }
            },
            {
              "title": "Asyncio Operations & OTel Spans",
              "type": "timeseries",
              "gridPos": { "h": 8, "w": 12, "x": 12, "y": 22 },
              "datasource": { "uid": "prometheus" },
              "targets": [
                { "expr": "sum(rate(ogx_requests_total{service_name=\"ogx\"}[5m]))", "legendFormat": "requests/s" },
                { "expr": "ogx_concurrent_requests{service_name=\"ogx\"}", "legendFormat": "concurrent requests" },
                { "expr": "sum(rate(vllm:request_success_total[5m]))", "legendFormat": "vLLM success/s" }
              ]
            }
          ]
        },
        {
          "title": "── FUTURE COMPONENTS ────────────────────────",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 22 },
          "collapsed": true,
          "panels": [
            {
              "title": "Extending This Dashboard",
              "type": "text",
              "gridPos": { "h": 10, "w": 24, "x": 0, "y": 23 },
              "options": { "mode": "markdown", "content": "### Adding New Components\\n\\nThis dashboard is designed to grow with your evaluation needs. Each new component follows the same pattern:\\n\\n1. **Instrument** the component with OpenTelemetry (metrics + traces)\\n2. **Point** it at the OTel Collector: `otel-collector-collector.perf-testing.svc:4317`\\n3. **Create a ServiceMonitor** if the component exposes a native `/metrics` endpoint\\n4. **Add panels** to the appropriate collapsible row above\\n\\n### Planned Component Sections\\n\\n| Component | Row | Key Metrics |\\n|---|---|---|\\n| **Document Ingestion** | Data Layer | docs/s, chunk size, embedding latency, pipeline throughput |\\n| **Vector Store (Milvus)** | Data Layer | query latency, index size, recall, connection pool |\\n| **MCP Gateway** | Service Connectivity | routing latency, message throughput, error rate by server |\\n| **RAG Pipeline** | Agentic Workflow | retrieval latency, context window fill %, rerank time |\\n| **Safety / Guardrails** | Agentic Workflow | check latency, block rate, false positive rate |\\n| **Agent Orchestrator** | Agentic Workflow | tool call count, turn depth, planning time |\\n| **Batch Processing** | Token Economics | batch size, queue depth, completion rate |\\n\\n### OTel Instrumentation Pattern\\n\\n```\\nenv:\\n- name: OTEL_SERVICE_NAME\\n  value: \\\"my-component\\\"\\n- name: OTEL_EXPORTER_OTLP_ENDPOINT\\n  value: \\\"http://otel-collector-collector.perf-testing.svc:4317\\\"\\n- name: OTEL_EXPORTER_OTLP_PROTOCOL\\n  value: \\\"grpc\\\"\\n```\\n\\nOnce a component sends metrics, they appear in Prometheus and can be queried in any panel above." }
            }
          ]
        }
      ],
      "schemaVersion": 39,
      "templating": { "list": [] },
      "time": { "from": "now-30m", "to": "now" },
      "title": "Performance Engineering Evaluation",
      "uid": "perf-eng-eval"
    }
CONFIGMAP_EOF

ok "8 dashboards created (OCP, GPU, LLM, Perf Eval, OGX Deep Dive, Responses API Eval, Distributed Traces, Perf Engineering Eval)"

# ── 9. Per-Process Resource Utilization (by node role) ─────────────────────
info "Creating Per-Process Instance Resource Utilization dashboard..."

cat <<'CONFIGMAP_EOF' | sed "s/GRAFANA_NS_PLACEHOLDER/${GRAFANA_NS}/g" | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-instance-resources
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  instance-resources.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "graphTooltip": 1,
      "refresh": "30s",
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "allValue": "",
            "current": {},
            "datasource": { "type": "prometheus", "uid": "prometheus" },
            "definition": "label_values(kube_node_role, role)",
            "hide": 0,
            "includeAll": true,
            "label": "Node Role",
            "multi": true,
            "name": "node_role",
            "options": [],
            "query": { "query": "label_values(kube_node_role, role)", "refId": "A" },
            "refresh": 2,
            "regex": "",
            "skipUrlSync": false,
            "sort": 1,
            "type": "query"
          },
          {
            "allValue": "",
            "current": {},
            "datasource": { "type": "prometheus", "uid": "prometheus" },
            "definition": "label_values(kube_pod_info, namespace)",
            "hide": 0,
            "includeAll": true,
            "label": "Namespace",
            "multi": true,
            "name": "namespace",
            "options": [],
            "query": { "query": "label_values(kube_pod_info, namespace)", "refId": "B" },
            "refresh": 2,
            "regex": "/^(?!openshift-|kube-|default$).*/",
            "skipUrlSync": false,
            "sort": 1,
            "type": "query"
          }
        ]
      },
      "panels": [
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "id": 100,
          "title": "$node_role",
          "type": "row",
          "repeat": "node_role",
          "repeatDirection": "h"
        },
        {
          "title": "Container CPU Utilization (%) — $node_role",
          "description": "CPU usage per container as % of node allocatable CPU. Stacked to 100% = node fully utilized.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 0, "y": 1 },
          "id": 101,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "percent", "min": 0, "max": 100, "custom": { "fillOpacity": 20, "lineWidth": 2, "spanNulls": true, "stacking": { "mode": "normal" }, "showPoints": "never" } },
            "overrides": []
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max", "lastNotNull"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "100 * sum(rate(container_cpu_usage_seconds_total{container!=\"\", container!=\"POD\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) / on(node) group_left() kube_node_status_allocatable{resource=\"cpu\"} * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}})"
            }
          ]
        },
        {
          "title": "Container Memory Working Set — $node_role",
          "description": "Active memory per container. Dashed line = node allocatable memory.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 12, "y": 1 },
          "id": 102,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "bytes", "min": 0, "custom": { "fillOpacity": 20, "lineWidth": 2, "spanNulls": true, "stacking": { "mode": "normal" }, "showPoints": "never" } },
            "overrides": [
              { "matcher": { "id": "byRegexp", "options": ".*capacity.*" }, "properties": [{ "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } }, { "id": "custom.lineWidth", "value": 2 }, { "id": "custom.fillOpacity", "value": 0 }, { "id": "custom.stacking", "value": { "mode": "none" } }, { "id": "color", "value": { "mode": "fixed", "fixedColor": "red" } }] }
            ]
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max", "lastNotNull"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{container!=\"\", container!=\"POD\"} * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}})"
            },
            {
              "expr": "kube_node_status_allocatable{resource=\"memory\"} * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{node}} capacity"
            }
          ]
        },
        {
          "title": "CPU Throttling by Container — $node_role",
          "description": "Percentage of CPU periods where a container was throttled. High throttling = container hitting its CPU limit.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 0, "y": 10 },
          "id": 103,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "percentunit", "min": 0, "max": 1, "custom": { "fillOpacity": 10, "lineWidth": 2, "spanNulls": true, "showPoints": "never", "thresholdsStyle": { "mode": "line" } }, "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 0.25 }, { "color": "red", "value": 0.5 }] } },
            "overrides": []
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "sum(rate(container_cpu_cfs_throttled_periods_total{container!=\"\", container!=\"POD\"}[5m]) / rate(container_cpu_cfs_periods_total{container!=\"\", container!=\"POD\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}})"
            }
          ]
        },
        {
          "title": "Memory vs Limit — $node_role",
          "description": "Memory usage as a fraction of each container's memory limit. Approaching 1.0 = risk of OOM kill.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 12, "y": 10 },
          "id": 104,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "percentunit", "min": 0, "max": 1, "custom": { "fillOpacity": 10, "lineWidth": 2, "spanNulls": true, "showPoints": "never", "thresholdsStyle": { "mode": "line" } }, "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 0.75 }, { "color": "red", "value": 0.9 }] } },
            "overrides": []
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "(sum by (container, pod, namespace) (container_memory_working_set_bytes{container!=\"\", container!=\"POD\", namespace=~\"$namespace\"}) / sum by (container, pod, namespace) (kube_pod_container_resource_limits{resource=\"memory\", namespace=~\"$namespace\"})) * on(namespace, pod) group_left(node) topk by (namespace, pod) (1, kube_pod_info{namespace=~\"$namespace\"}) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}})"
            }
          ]
        },
        {
          "title": "Container Network I/O — $node_role",
          "description": "TX (positive) and RX (negative) per pod. Identifies network-heavy processes.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 24, "x": 0, "y": 19 },
          "id": 105,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "Bps", "custom": { "fillOpacity": 15, "lineWidth": 2, "spanNulls": true, "showPoints": "never" } },
            "overrides": [
              { "matcher": { "id": "byRegexp", "options": ".*RX$" }, "properties": [{ "id": "custom.transform", "value": "negative-Y" }] }
            ]
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "sum(rate(container_network_transmit_bytes_total{interface!~\"lo|veth.*\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{pod}} TX"
            },
            {
              "expr": "sum(rate(container_network_receive_bytes_total{interface!~\"lo|veth.*\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{pod}} RX"
            }
          ]
        },
        {
          "title": "Container Filesystem I/O — $node_role",
          "description": "Read/write throughput per container. Helps identify disk-heavy processes.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 0, "y": 28 },
          "id": 106,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "Bps", "custom": { "fillOpacity": 10, "lineWidth": 2, "spanNulls": true, "showPoints": "never" } },
            "overrides": [
              { "matcher": { "id": "byRegexp", "options": ".*write.*" }, "properties": [{ "id": "custom.transform", "value": "negative-Y" }] }
            ]
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["mean", "max"], "placement": "bottom", "sortBy": "Max", "sortDesc": true } },
          "targets": [
            {
              "expr": "sum(rate(container_fs_reads_bytes_total{container!=\"\", container!=\"POD\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}}) read"
            },
            {
              "expr": "sum(rate(container_fs_writes_bytes_total{container!=\"\", container!=\"POD\"}[5m]) * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}}) write"
            }
          ]
        },
        {
          "title": "Container Restarts — $node_role",
          "description": "Cumulative restart count per container. Spikes indicate crashes or OOM kills.",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 12, "y": 28 },
          "id": 107,
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "fieldConfig": {
            "defaults": { "unit": "short", "min": 0, "custom": { "fillOpacity": 0, "lineWidth": 2, "spanNulls": true, "showPoints": "auto", "pointSize": 5 } },
            "overrides": []
          },
          "options": { "legend": { "displayMode": "table", "calcs": ["lastNotNull", "max"], "placement": "bottom", "sortBy": "Last *", "sortDesc": true } },
          "targets": [
            {
              "expr": "sum(kube_pod_container_status_restarts_total * on(namespace, pod) group_left(node) kube_pod_info{namespace=~\"$namespace\"}) by (container, pod, node) * on(node) group_left() label_replace(kube_node_role{role=~\"$node_role\"}, \"node\", \"$1\", \"node\", \"(.*)\")",
              "legendFormat": "{{container}} ({{pod}})"
            }
          ]
        }
      ],
      "time": { "from": "now-30m", "to": "now" },
      "title": "Per-Process Instance Utilization",
      "uid": "instance-resources"
    }
CONFIGMAP_EOF

ok "Per-Process Instance Resource Utilization dashboard created"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AI GATEWAY DASHBOARD — Kuadrant/Authorino/Limitador resource monitoring
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating AI Gateway dashboard..."

apply_cm <<'CONFIGMAP_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-ai-gateway
  namespace: GRAFANA_NS_PLACEHOLDER
data:
  ai-gateway.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "title": "Full Pipeline Latency View (Gateway → Kuadrant → BBR → Backend)",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "collapsed": false
        },
        {
          "title": "E2E Latency (p50/p95/p99)",
          "type": "stat",
          "gridPos": { "h": 5, "w": 8, "x": 0, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "p50" },
            { "expr": "histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "p95" },
            { "expr": "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "p99" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms", "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 100}, {"color": "red", "value": 500}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "none", "textMode": "value_and_name" }
        },
        {
          "title": "Request Rate",
          "type": "stat",
          "gridPos": { "h": 5, "w": 4, "x": 8, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m]))", "legendFormat": "req/s" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color": "green", "value": null}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" }
        },
        {
          "title": "Kuadrant Allowed",
          "type": "stat",
          "gridPos": { "h": 5, "w": 4, "x": 12, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(kuadrant_allowed[5m]))", "legendFormat": "allowed/s" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color": "green", "value": null}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" }
        },
        {
          "title": "Kuadrant Denied",
          "type": "stat",
          "gridPos": { "h": 5, "w": 4, "x": 16, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(kuadrant_denied[5m]))", "legendFormat": "denied/s" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.1}, {"color": "red", "value": 1}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" }
        },
        {
          "title": "Errors",
          "type": "stat",
          "gridPos": { "h": 5, "w": 4, "x": 20, "y": 1 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code!=\"200\", response_code!=\"0\"}[5m]))", "legendFormat": "err/s" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.1}, {"color": "red", "value": 1}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" }
        },
        {
          "title": "Pipeline Step Latency (Request Path)",
          "type": "bargauge",
          "gridPos": { "h": 9, "w": 12, "x": 0, "y": 6 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.50, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "1. Gateway E2E (includes all)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-provider-resolver\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-provider-resolver\"}[5m])) * 1000", "legendFormat": "2. BBR: model-provider-resolver" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-extractor\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-extractor\"}[5m])) * 1000", "legendFormat": "3. BBR: model-extractor" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"api-translation\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"api-translation\"}[5m])) * 1000", "legendFormat": "4. BBR: api-translation (req)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"apikey-injection\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"apikey-injection\"}[5m])) * 1000", "legendFormat": "5. BBR: apikey-injection" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"response\", plugin_name=\"api-translation\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"response\", plugin_name=\"api-translation\"}[5m])) * 1000", "legendFormat": "6. BBR: api-translation (resp)" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms", "thresholds": { "steps": [{"color": "blue", "value": null}, {"color": "green", "value": 0.01}, {"color": "yellow", "value": 1}, {"color": "red", "value": 10}] } } },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] }, "showUnfilled": true, "valueMode": "text" }
        },
        {
          "title": "E2E Latency Over Time (Gateway)",
          "type": "timeseries",
          "gridPos": { "h": 9, "w": 12, "x": 12, "y": 6 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(istio_request_duration_milliseconds_sum{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])) / sum(rate(istio_request_duration_milliseconds_count{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m]))", "legendFormat": "E2E avg" },
            { "expr": "histogram_quantile(0.50, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "E2E p50" },
            { "expr": "histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "E2E p95" },
            { "expr": "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m])))", "legendFormat": "E2E p99" },
            { "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\"}[5m]))", "legendFormat": "Envoy RPS", "refId": "RPS" }
          ],
          "fieldConfig": { "defaults": { "unit": "ms", "custom": { "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "E2E avg" }, "properties": [{ "id": "color", "value": { "fixedColor": "blue", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "E2E p99" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "E2E p95" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "E2E p50" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "Envoy RPS" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "reqps" }, { "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] }] }
        },
        {
          "title": "AI Gateway Pods CPU & Memory",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"kuadrant-system\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM1" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"kuadrant-system\", container!=\"\", container!=\"POD\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM2" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM3" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM4" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "custom": { "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byRegexp", "options": ".*Mem.*" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "bytes" }] }] }
        },
        {
          "title": "Kuadrant Auth/RateLimit Activity",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 6, "x": 12, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(kuadrant_allowed[5m]))", "legendFormat": "Allowed" },
            { "expr": "sum(rate(kuadrant_denied[5m]))", "legendFormat": "Denied" },
            { "expr": "sum(rate(kuadrant_hits[5m]))", "legendFormat": "Cache Hits" },
            { "expr": "sum(rate(kuadrant_errors[5m]))", "legendFormat": "Errors" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps", "custom": { "fillOpacity": 20, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "Allowed" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "Denied" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "Errors" }, "properties": [{ "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] }] }
        },
        {
          "title": "Response Codes",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 6, "x": 18, "y": 15 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code=\"200\"}[5m]))", "legendFormat": "200 OK" },
            { "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code=\"0\"}[5m]))", "legendFormat": "0 (Disconnect)" },
            { "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code=~\"4..\"}[5m]))", "legendFormat": "4xx" },
            { "expr": "sum(rate(istio_requests_total{source_workload=~\"maas-default-gateway.*\", response_code=~\"5..\"}[5m]))", "legendFormat": "5xx" }
          ],
          "fieldConfig": { "defaults": { "unit": "reqps", "custom": { "fillOpacity": 20, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "200 OK" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "4xx" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "5xx" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }] }
        },
        {
          "title": "BBR Plugin Internals (Payload Processing)",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 22 },
          "collapsed": false
        },
        {
          "title": "Request Rate",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 0, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(bbr_success_total{namespace=\"openshift-ingress\"}[5m]))", "legendFormat": "req/s" }],
          "fieldConfig": { "defaults": { "unit": "reqps", "thresholds": { "steps": [{"color": "green", "value": null}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" }
        },
        {
          "title": "Total Processed",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 4, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(bbr_success_total{namespace=\"openshift-ingress\"})", "legendFormat": "Total" }],
          "fieldConfig": { "defaults": { "unit": "short", "thresholds": { "steps": [{"color": "blue", "value": null}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "none" }
        },
        {
          "title": "Response Latency",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 8, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m]))", "legendFormat": "Avg" }],
          "fieldConfig": { "defaults": { "unit": "s", "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.001}, {"color": "red", "value": 0.01}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "none" }
        },
        {
          "title": "Plugin Latency + Payload CPU",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 23 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-provider-resolver\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-provider-resolver\"}[5m]))", "legendFormat": "model-provider-resolver (req)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-extractor\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"model-extractor\"}[5m]))", "legendFormat": "model-extractor (req)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"api-translation\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"api-translation\"}[5m]))", "legendFormat": "api-translation (req)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"apikey-injection\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\", plugin_name=\"apikey-injection\"}[5m]))", "legendFormat": "apikey-injection (req)" },
            { "expr": "sum(rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"response\", plugin_name=\"api-translation\"}[5m])) / sum(rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"response\", plugin_name=\"api-translation\"}[5m]))", "legendFormat": "api-translation (resp)" },
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-ingress\", pod=~\"payload-processing.*\", container!=\"\", container!=\"POD\"}[5m]))", "legendFormat": "Payload CPU", "refId": "CPU" }
          ],
          "fieldConfig": { "defaults": { "unit": "s", "custom": { "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "Payload CPU" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "short" }, { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }] }
        },
        {
          "title": "Avg Plugin Latency",
          "type": "bargauge",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 27 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum by (plugin_name) (rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\"}[5m])) / sum by (plugin_name) (rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\"}[5m]))", "legendFormat": "{{plugin_name}} (req)" },
            { "expr": "sum by (plugin_name) (rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m])) / sum by (plugin_name) (rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m]))", "legendFormat": "{{plugin_name}} (resp)" }
          ],
          "fieldConfig": { "defaults": { "unit": "s", "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.001}, {"color": "red", "value": 0.01}] } } },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] }, "showUnfilled": true, "valueMode": "text" }
        },
        {
          "title": "Plugin Latency + Payload Memory",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 31 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum by (plugin_name) (rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"request\"}[5m])) / sum by (plugin_name) (rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"request\"}[5m]))", "legendFormat": "{{plugin_name}} (req)" },
            { "expr": "sum by (plugin_name) (rate(bbr_plugin_duration_seconds_sum{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m])) / sum by (plugin_name) (rate(bbr_plugin_duration_seconds_count{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m]))", "legendFormat": "{{plugin_name}} (resp)" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"openshift-ingress\", pod=~\"payload-processing.*\", container!=\"\", container!=\"POD\"})", "legendFormat": "Payload Memory", "refId": "MEM" }
          ],
          "fieldConfig": { "defaults": { "unit": "s", "custom": { "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "Payload Memory" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "bytes" }, { "id": "color", "value": { "fixedColor": "purple", "mode": "fixed" } }] }] }
        },
        {
          "title": "P99 Latency + Request Rate",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "histogram_quantile(0.99, sum by (plugin_name, le) (rate(bbr_plugin_duration_seconds_bucket{namespace=\"openshift-ingress\", extension_point=\"request\"}[5m])))", "legendFormat": "{{plugin_name}} (req) p99" },
            { "expr": "histogram_quantile(0.99, sum by (plugin_name, le) (rate(bbr_plugin_duration_seconds_bucket{namespace=\"openshift-ingress\", extension_point=\"response\"}[5m])))", "legendFormat": "{{plugin_name}} (resp) p99" },
            { "expr": "sum(rate(bbr_success_total{namespace=\"openshift-ingress\"}[5m]))", "legendFormat": "Request Rate", "refId": "RATE" }
          ],
          "fieldConfig": { "defaults": { "unit": "s", "custom": { "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [{ "matcher": { "id": "byName", "options": "Request Rate" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "reqps" }, { "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] }] }
        },
        {
          "title": "Pod Failures Over Time",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 35 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "increase(kube_pod_container_status_restarts_total{namespace=\"openshift-ingress\"}[5m])", "legendFormat": "{{pod}} restarts" },
            { "expr": "kube_pod_status_phase{namespace=\"openshift-ingress\", phase=\"Failed\"}", "legendFormat": "{{pod}} failed" },
            { "expr": "kube_pod_container_status_waiting_reason{namespace=\"openshift-ingress\", reason=~\"CrashLoopBackOff|Error|ImagePullBackOff\"}", "legendFormat": "{{pod}} {{reason}}" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "custom": { "fillOpacity": 20, "lineWidth": 2 }, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}] } } }
        },
        {
          "title": "Ingress & Gateway Services (openshift-ingress)",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 42 },
          "collapsed": false
        },
        {
          "title": "Per-Pod CPU % of Limit",
          "type": "bargauge",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\"}[5m])) by (pod) / sum(kube_pod_container_resource_limits{namespace=\"openshift-ingress\", resource=\"cpu\", container!=\"\"}) by (pod) * 100", "legendFormat": "{{pod}}" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}] } } },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] }, "showUnfilled": true }
        },
        {
          "title": "Per-Pod Memory % of Limit",
          "type": "bargauge",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 43 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(container_memory_working_set_bytes{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\"}) by (pod) / sum(kube_pod_container_resource_limits{namespace=\"openshift-ingress\", resource=\"memory\", container!=\"\"}) by (pod) * 100", "legendFormat": "{{pod}}" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}] } } },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] }, "showUnfilled": true }
        },
        {
          "title": "Gateway CPU & Memory Over Time",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 51 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "custom": { "lineWidth": 1, "fillOpacity": 10 } }, "overrides": [{ "matcher": { "id": "byRegexp", "options": ".*Mem.*" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "bytes" }] }] }
        },
        {
          "title": "Simulator & AB Test CPU & Memory",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 59 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod=~\"payload-ab-test.*|llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"openshift-ingress\", container!=\"\", container!=\"POD\", pod=~\"payload-ab-test.*|llm-d-inference-sim.*\"}) by (pod)", "legendFormat": "{{pod}} Mem", "refId": "MEM" }
          ],
          "fieldConfig": { "defaults": { "unit": "short", "custom": { "lineWidth": 1, "fillOpacity": 10 } }, "overrides": [{ "matcher": { "id": "byRegexp", "options": ".*Mem.*" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "bytes" }] }] }
        },
        {
          "title": "Gateway Network I/O",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 51 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"openshift-ingress\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} rx" },
            { "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"openshift-ingress\", pod!~\".*payload-ab-test.*\", pod!~\".*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} tx" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" } }
        },
        {
          "title": "Simulator & AB Test Network I/O",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 59 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"openshift-ingress\", pod=~\".*payload-ab-test.*|.*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} rx" },
            { "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"openshift-ingress\", pod=~\".*payload-ab-test.*|.*llm-d-inference-sim.*\"}[5m])) by (pod)", "legendFormat": "{{pod}} tx" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" } }
        },
        {
          "title": "MaaS Services",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 67 },
          "collapsed": false
        },
        {
          "title": "MaaS DB CPU % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 6, "x": 0, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}[5m])) / sum(kube_pod_container_resource_limits{namespace=\"maas-db\", resource=\"cpu\", container!=\"\"}) * 100", "legendFormat": "CPU" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "MaaS DB Mem % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 6, "x": 6, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(container_memory_working_set_bytes{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}) / sum(kube_pod_container_resource_limits{namespace=\"maas-db\", resource=\"memory\", container!=\"\"}) * 100", "legendFormat": "Memory" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "MaaS API CPU % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 6, "x": 12, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}[5m])) / sum(kube_pod_container_resource_limits{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", resource=\"cpu\", container!=\"\"}) * 100", "legendFormat": "CPU" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "MaaS API Mem % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 6, "x": 18, "y": 68 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(container_memory_working_set_bytes{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}) / sum(kube_pod_container_resource_limits{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", resource=\"memory\", container!=\"\"}) * 100", "legendFormat": "Memory" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "MaaS DB Resources",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 12, "x": 0, "y": 73 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"maas-db\", container!=\"\", container!=\"POD\"}) by (pod) / 1024 / 1024 / 1024", "legendFormat": "{{pod}} Mem (GB)", "refId": "MEM" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{ "matcher": { "id": "byRegexp", "options": ".*Mem.*" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "decgbytes" }] }] }
        },
        {
          "title": "MaaS API Resources",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 12, "x": 12, "y": 73 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" },
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"redhat-ods-applications\", pod=~\"maas-api.*\", container!=\"\", container!=\"POD\"}) by (pod) / 1024 / 1024", "legendFormat": "{{pod}} Mem (MB)", "refId": "MEM" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [{ "matcher": { "id": "byRegexp", "options": ".*Mem.*" }, "properties": [{ "id": "custom.axisPlacement", "value": "right" }, { "id": "unit", "value": "decmbytes" }] }] }
        },
        {
          "title": "AI Gateway (Kuadrant)",
          "type": "row",
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 79 },
          "collapsed": false
        },
        {
          "title": "Kuadrant CPU % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 8, "x": 0, "y": 80 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "avg(sum(rate(container_cpu_usage_seconds_total{namespace=\"kuadrant-system\", container!=\"\", container!=\"POD\"}[5m])) by (pod) / sum(kube_pod_container_resource_limits{namespace=\"kuadrant-system\", resource=\"cpu\", container!=\"\"}) by (pod) * 100)", "legendFormat": "Avg CPU" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "Kuadrant Mem % Limit",
          "type": "gauge",
          "gridPos": { "h": 5, "w": 8, "x": 8, "y": 80 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "avg(sum(container_memory_working_set_bytes{namespace=\"kuadrant-system\", container!=\"\", container!=\"POD\"}) by (pod) / sum(kube_pod_container_resource_limits{namespace=\"kuadrant-system\", resource=\"memory\", container!=\"\"}) by (pod) * 100)", "legendFormat": "Avg Mem" }],
          "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 60}, {"color": "red", "value": 90}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "title": "Kuadrant Restarts",
          "type": "stat",
          "gridPos": { "h": 5, "w": 8, "x": 16, "y": 80 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [{ "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"kuadrant-system\"})", "legendFormat": "Total" }],
          "fieldConfig": { "defaults": { "thresholds": { "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 5}, {"color": "red", "value": 10}] } } },
          "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value" }
        },
        {
          "title": "Authorino/Limitador Resources",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 85 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"kuadrant-system\", pod=~\"authorino.*|limitador.*\", container!=\"\", container!=\"POD\"}[5m])) by (pod)", "legendFormat": "{{pod}} CPU" }
          ],
          "fieldConfig": { "defaults": { "unit": "short" } }
        },
        {
          "title": "Kuadrant Network I/O",
          "type": "timeseries",
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 85 },
          "datasource": { "type": "prometheus", "uid": "${DS_OPENSHIFT_PROMETHEUS}" },
          "targets": [
            { "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"kuadrant-system\"}[5m])) by (pod)", "legendFormat": "{{pod}} rx" },
            { "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"kuadrant-system\"}[5m])) by (pod)", "legendFormat": "{{pod}} tx" }
          ],
          "fieldConfig": { "defaults": { "unit": "Bps" } }
        }
      ],
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "DS_OPENSHIFT_PROMETHEUS",
            "type": "datasource",
            "query": "prometheus",
            "current": { "text": "OpenShift Prometheus", "value": "OpenShift Prometheus" },
            "hide": 2
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "AI Gateway & MaaS Resources",
      "uid": "ai-gateway-resources"
    }
CONFIGMAP_EOF

ok "AI Gateway dashboard created (BBR + Ingress + MaaS + Kuadrant)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. DEPLOY GRAFANA
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Deploying Grafana..."

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${GRAFANA_NS}
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      serviceAccountName: ${GRAFANA_SA}
      nodeSelector:
        node-role.kubernetes.io/loadgen-worker: ""
      containers:
      - name: grafana
        image: docker.io/grafana/grafana:11.4.0
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: "${GRAFANA_ADMIN_USER:-admin}"
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "${GRAFANA_ADMIN_PASSWORD:-admin}"
        - name: GF_USERS_ALLOW_SIGN_UP
          value: "false"
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "true"
        - name: GF_AUTH_ANONYMOUS_ORG_ROLE
          value: "Viewer"
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: "1"
            memory: 512Mi
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: dashboard-providers
          mountPath: /etc/grafana/provisioning/dashboards
        - name: dashboard-ocp
          mountPath: /var/lib/grafana/dashboards/ocp
        - name: dashboard-gpu
          mountPath: /var/lib/grafana/dashboards/gpu
        - name: dashboard-llm
          mountPath: /var/lib/grafana/dashboards/llm
        - name: dashboard-perf-eval
          mountPath: /var/lib/grafana/dashboards/perf-eval
        - name: dashboard-llamastack
          mountPath: /var/lib/grafana/dashboards/llamastack
        - name: dashboard-responses-api
          mountPath: /var/lib/grafana/dashboards/responses-api
        - name: dashboard-traces
          mountPath: /var/lib/grafana/dashboards/traces
        - name: dashboard-perf-eng
          mountPath: /var/lib/grafana/dashboards/perf-eng
        - name: dashboard-instance-resources
          mountPath: /var/lib/grafana/dashboards/instance-resources
        - name: dashboard-ai-gateway
          mountPath: /var/lib/grafana/dashboards/ai-gateway
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboard-providers
        configMap:
          name: grafana-dashboards
      - name: dashboard-ocp
        configMap:
          name: grafana-dashboard-ocp
      - name: dashboard-gpu
        configMap:
          name: grafana-dashboard-gpu
      - name: dashboard-llm
        configMap:
          name: grafana-dashboard-llm
      - name: dashboard-perf-eval
        configMap:
          name: grafana-dashboard-perf-eval
      - name: dashboard-llamastack
        configMap:
          name: grafana-dashboard-llamastack
      - name: dashboard-responses-api
        configMap:
          name: grafana-dashboard-responses-api
      - name: dashboard-traces
        configMap:
          name: grafana-dashboard-traces
      - name: dashboard-perf-eng
        configMap:
          name: grafana-dashboard-perf-eng
      - name: dashboard-instance-resources
        configMap:
          name: grafana-dashboard-instance-resources
      - name: dashboard-ai-gateway
        configMap:
          name: grafana-dashboard-ai-gateway
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: ${GRAFANA_NS}
  labels:
    app: grafana
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
    name: http
EOF

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. EXPOSE VIA ROUTE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
  namespace: ${GRAFANA_NS}
spec:
  to:
    kind: Service
    name: grafana
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

info "Waiting for Grafana pod..."
oc rollout status deployment/grafana -n "${GRAFANA_NS}" --timeout=120s 2>/dev/null || \
  warn "Grafana not ready yet — check: oc get pods -n ${GRAFANA_NS} -l app=grafana"

GRAFANA_URL=$(oc get route grafana -n "${GRAFANA_NS}" -o jsonpath='{.spec.host}' 2>/dev/null)

echo ""
echo "============================================"
ok "Grafana is deployed!"
echo ""
info "URL:      https://${GRAFANA_URL}"
info "Login:    admin / admin"
echo ""
info "Dashboards:"
info "  1. OCP Cluster Overview     — CPU, memory, network, pods"
info "  2. GPU Metrics (DCGM)       — utilization, memory, temp, power"
info "  3. LLM Inference            — vLLM + OGX metrics, latency, tokens"
info "  4. Performance Evaluation   — AI Stack → GPU → Per-Instance (combined)"
info "  5. OGX Deep Dive    — GenAI, HTTP API, DB pool, process health"
info "  6. Responses API Evaluation — latency breakdown, throughput, vLLM, GPU, DB, resources"
info "  7. Distributed Traces     — trace metrics, overhead analysis, OTel Collector"
info "  8. Perf Engineering Eval  — modular single-run evaluation, extensible for future components"
echo ""
info "  Trace metrics: OTel Collector exports to Prometheus (filter by service_name: ogx, vllm-inference)"
echo ""
info "To remove:  bash ./grafana-quickstart.sh teardown"
echo "============================================"
