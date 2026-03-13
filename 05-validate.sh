#!/usr/bin/env bash
# ============================================================================
# 05-validate.sh — Run validation checklist before benchmarking
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
# Intentionally no set -e: this script must run ALL checks and report a summary.

echo ""
echo "============================================"
echo "  Validation Checklist"
echo "  Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"

PASS=0
FAIL=0
WARN_COUNT=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
    PASS=$((PASS + 1))
  else
    err "$desc"
    FAIL=$((FAIL + 1))
  fi
}

check_warn() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
    PASS=$((PASS + 1))
  else
    warn "$desc"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CLUSTER HEALTH
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Cluster Health ──"

# 6 nodes Ready
NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo 0)
check "All 6 nodes are Ready (found: ${NODE_COUNT})" test "${NODE_COUNT}" -eq 6

# Masters have no user pods
MASTER_USER_PODS=$(oc get pods -n "${PERF_NAMESPACE}" -o wide --no-headers 2>/dev/null | grep -c "master" || true)
check "No user pods on master nodes (found: ${MASTER_USER_PODS})" test "${MASTER_USER_PODS}" -eq 0

# All cluster operators available
DEGRADED_OPS=$(oc get co --no-headers 2>/dev/null | awk '$5=="True"' | wc -l | tr -d ' ' || true)
check "No degraded cluster operators (found: ${DEGRADED_OPS})" test "${DEGRADED_OPS}" -eq 0

# etcd health
ETCD_MEMBERS=$(oc get etcd cluster -o jsonpath='{.status.conditions[?(@.type=="EtcdMembersAvailable")].status}' 2>/dev/null || echo "")
check "etcd members available" test "${ETCD_MEMBERS}" = "True"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NODE ROLES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Node Roles ──"

APP_LABELED=$(oc get nodes -l node-role.kubernetes.io/app-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "App worker node labeled (found: ${APP_LABELED})" test "${APP_LABELED}" -ge 1

LOADGEN_LABELED=$(oc get nodes -l node-role.kubernetes.io/loadgen-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "Load-gen worker node labeled (found: ${LOADGEN_LABELED})" test "${LOADGEN_LABELED}" -ge 1

GPU_LABELED=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "GPU node detected (found: ${GPU_LABELED})" test "${GPU_LABELED}" -ge 1

# GPU taint check
GPU_NODE=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$GPU_NODE" ]]; then
  GPU_TAINTED=$(oc get node "${GPU_NODE}" -o jsonpath='{.spec.taints}' 2>/dev/null | grep -c "nvidia.com/gpu" || true)
  check_warn "GPU node has nvidia.com/gpu taint" test "${GPU_TAINTED}" -ge 1

  GPU_COUNT=$(oc get node "${GPU_NODE}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
  check "GPU node shows ${TENSOR_PARALLEL_SIZE} GPUs (found: ${GPU_COUNT})" test "${GPU_COUNT}" -eq "${TENSOR_PARALLEL_SIZE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# POD PLACEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Pod Placement ──"

# Helper: check pod is on the correct node type
check_pod_on_node() {
  local label="$1" expected_instance="$2" desc="$3"
  local pod_node
  pod_node=$(oc get pods -l "${label}" -n "${PERF_NAMESPACE}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
  if [[ -z "$pod_node" ]]; then
    err "${desc} — pod not found"
    FAIL=$((FAIL + 1))
    return
  fi
  local node_type
  node_type=$(oc get node "${pod_node}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")
  if [[ "$node_type" == "$expected_instance" ]]; then
    ok "${desc} (on ${pod_node})"
    PASS=$((PASS + 1))
  else
    err "${desc} — on ${pod_node} (${node_type}), expected ${expected_instance}"
    FAIL=$((FAIL + 1))
  fi
}

check_pod_on_node "app=postgresql" "${APP_WORKER_INSTANCE_TYPE}" "PostgreSQL pod on app worker"

LLAMA_PODS=$(oc get pods -l app=llama-stack -n "${PERF_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
check_warn "Llama Stack pod exists (found: ${LLAMA_PODS})" test "${LLAMA_PODS}" -ge 1

VLLM_PODS=$(oc get pods -l app=vllm-inference -n "${PERF_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
check_warn "vLLM pod exists (found: ${VLLM_PODS})" test "${VLLM_PODS}" -ge 1

if [[ "${MCP_KUBERNETES_ENABLED}" == "true" ]]; then
  check_pod_on_node "app=kubernetes-mcp-server" "${APP_WORKER_INSTANCE_TYPE}" "K8s MCP server on app worker"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STORAGE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Storage ──"

MODEL_PVC_PHASE=$(oc get pvc model-storage -n "${PERF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
check "model-storage PVC is Bound (${MODEL_PVC_PHASE})" test "${MODEL_PVC_PHASE}" = "Bound"

PG_PVC_PHASE=$(oc get pvc postgresql-data -n "${PERF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
check "postgresql-data PVC is Bound (${PG_PVC_PHASE})" test "${PG_PVC_PHASE}" = "Bound"

BENCH_PVC_PHASE=$(oc get pvc benchmark-results -n "${PERF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
check_warn "benchmark-results PVC is Bound (${BENCH_PVC_PHASE}) — stays Pending until a pod claims it" test "${BENCH_PVC_PHASE}" = "Bound"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SERVICES & ENDPOINTS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Services ──"

check "postgresql service exists" \
  oc get svc postgresql -n "${PERF_NAMESPACE}"

check_warn "kubernetes-mcp-server service exists" \
  oc get svc kubernetes-mcp-server -n "${PERF_NAMESPACE}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# METRICS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Metrics Pipeline ──"

PROM_RUNNING=$(oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c Running || true)
check_warn "Prometheus is running (found: ${PROM_RUNNING} pods)" test "${PROM_RUNNING}" -ge 1

DCGM_RUNNING=$(oc get pods -n nvidia-gpu-operator -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -c Running || true)
check_warn "DCGM exporter pods running (found: ${DCGM_RUNNING})" test "${DCGM_RUNNING}" -ge 1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SMOKE TESTS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "── Smoke Tests ──"

# PostgreSQL connectivity
PG_POD=$(oc get pod -l app=postgresql -n "${PERF_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$PG_POD" ]]; then
  check "PostgreSQL responds to pg_isready" \
    oc exec "${PG_POD}" -n "${PERF_NAMESPACE}" -- pg_isready -U "${POSTGRESQL_USER}" -d "${POSTGRESQL_DB}"

  PG_CONNECT=$(oc exec "${PG_POD}" -n "${PERF_NAMESPACE}" -- \
    psql -U "${POSTGRESQL_USER}" -d "${POSTGRESQL_DB}" -tAc "SELECT 1;" 2>/dev/null || echo "")
  check "PostgreSQL user '${POSTGRESQL_USER}' can connect to '${POSTGRESQL_DB}'" test "${PG_CONNECT}" = "1"
fi

# GPU check (nvidia-smi)
VLLM_POD=$(oc get pod -l app=vllm-inference -n "${PERF_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$VLLM_POD" ]]; then
  check_warn "nvidia-smi runs in vLLM pod" \
    oc exec "${VLLM_POD}" -n "${PERF_NAMESPACE}" -- nvidia-smi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SUMMARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "============================================"
echo "  Validation Results"
echo "  Passed:   ${PASS}"
echo "  Failed:   ${FAIL}"
echo "  Warnings: ${WARN_COUNT}"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  err "Fix the above failures before running benchmarks."
  echo ""
  info "Common fixes:"
  info "  - vLLM not ready? Model may still be loading (10-15 min for 70B)"
  info "  - Pod on wrong node? Check nodeSelector in deployment YAML"
  info "  - PVC not bound? Check storage class: oc get sc"
  info "  - GPU not detected? Wait for GPU driver: oc get pods -n nvidia-gpu-operator"
  exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
  echo ""
  warn "Some optional checks had warnings. Review above before benchmarking."
  echo ""
  info "Next step: ./06-deploy-benchmark.sh"
else
  echo ""
  ok "All checks passed. Ready for benchmarking."
  echo ""
  info "Next step: ./06-deploy-benchmark.sh"
fi

