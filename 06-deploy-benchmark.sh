#!/usr/bin/env bash
# ============================================================================
# 06-deploy-benchmark.sh — Deploy the benchmark runner pod on the load-gen worker
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}"

echo ""
echo "============================================"
echo "  Deploying Benchmark Runner"
echo "  Namespace: ${PERF_NAMESPACE}"
echo "  Node:      loadgen-worker"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"
ok "Connected to cluster as $(oc whoami)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. DEPLOY BENCHMARK RUNNER POD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Deploying benchmark-runner pod..."

oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: benchmark-runner
  namespace: ${PERF_NAMESPACE}
  labels:
    app: benchmark-runner
    role: loadgen
spec:
  nodeSelector:
    node-role.kubernetes.io/loadgen-worker: ""
  containers:
  - name: bench
    image: ${GUIDELLM_IMAGE}
    command: ["sleep", "infinity"]
    env:
    - name: LLAMA_STACK_URL
      value: "${LLAMA_STACK_URL}"
    - name: VLLM_URL
      value: "http://vllm-inference:8000"
    - name: MODEL_ID
      value: "${MODEL_ID}"
    - name: PERF_NAMESPACE
      value: "${PERF_NAMESPACE}"
    - name: MLFLOW_TRACKING_URI
      value: "${MLFLOW_TRACKING_URI}"
    - name: MLFLOW_TRACKING_USERNAME
      value: "${MLFLOW_TRACKING_USERNAME}"
    - name: MLFLOW_TRACKING_PASSWORD
      value: "${MLFLOW_TRACKING_PASSWORD}"
    - name: MLFLOW_WORKSPACE
      value: "${MLFLOW_WORKSPACE}"
    - name: OPENBLAS_NUM_THREADS
      value: "1"
    - name: HF_HOME
      value: "/tmp/hf_cache"
    - name: TRANSFORMERS_CACHE
      value: "/tmp/hf_cache"
    - name: GIT_PYTHON_REFRESH
      value: "quiet"
    - name: PYTHONPATH
      value: "/tmp/guidellm-upgrade:/tmp/pylib"
    - name: PATH
      value: "/tmp/guidellm-upgrade/bin:/opt/guidellm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    resources:
      requests:
        cpu: "${GUIDELLM_CPU_REQUEST}"
        memory: "${GUIDELLM_MEM_REQUEST}"
      limits:
        cpu: "${GUIDELLM_CPU_LIMIT}"
        memory: "${GUIDELLM_MEM_LIMIT}"
    volumeMounts:
    - name: results
      mountPath: /results
    - name: scripts
      mountPath: /scripts
  volumes:
  - name: results
    persistentVolumeClaim:
      claimName: benchmark-results
  - name: scripts
    emptyDir: {}
  restartPolicy: Never
EOF

info "Waiting for benchmark-runner pod to be ready..."
oc wait --for=condition=Ready pod/benchmark-runner -n "${PERF_NAMESPACE}" --timeout=180s 2>/dev/null || \
  warn "Pod not yet ready — check: oc get pod benchmark-runner -n ${PERF_NAMESPACE}"

ok "benchmark-runner pod deployed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. INSTALL BENCHMARK TOOLS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing benchmark tools in the pod (this takes 1-2 minutes)..."

oc exec benchmark-runner -n "${PERF_NAMESPACE}" -- bash -c '
  pip install --quiet --no-cache-dir --target=/tmp/pylib \
    mlflow-skinny \
    urllib3 \
    2>&1 | tail -3
'
ok "MLflow + deps installed"

info "Upgrading GuideLLM to v0.7.1 (Responses API support)..."
oc exec benchmark-runner -n "${PERF_NAMESPACE}" -- bash -c '
  pip install --quiet --no-cache-dir --target=/tmp/guidellm-upgrade \
    "guidellm[recommended]==0.7.1" \
    2>&1 | tail -3
'
ok "GuideLLM v0.7.1 installed to /tmp/guidellm-upgrade"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2b. GRANT MONITORING PERMISSIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Granting cluster-monitoring-view to benchmark pod's service account..."
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z default -n "${PERF_NAMESPACE}" 2>/dev/null || true
ok "Monitoring permissions granted"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2c. COPY LOAD TEST SCRIPT INTO POD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOAD_TEST_SCRIPT="${SCRIPT_DIR}/06-load-test.py"
if [[ -f "$LOAD_TEST_SCRIPT" ]]; then
  info "Copying 06-load-test.py into the pod..."
  oc cp "$LOAD_TEST_SCRIPT" "${PERF_NAMESPACE}/benchmark-runner:/scripts/06-load-test.py"
  ok "Load test script copied to /scripts/06-load-test.py"
else
  warn "06-load-test.py not found at ${LOAD_TEST_SCRIPT} — copy manually"
fi

GUIDELLM_SCRIPT="${SCRIPT_DIR}/run_guidellm_bench.py"
if [[ -f "$GUIDELLM_SCRIPT" ]]; then
  info "Copying run_guidellm_bench.py into the pod..."
  oc cp "$GUIDELLM_SCRIPT" "${PERF_NAMESPACE}/benchmark-runner:/scripts/run_guidellm_bench.py"
  ok "GuideLLM benchmark script copied to /scripts/run_guidellm_bench.py"
else
  warn "run_guidellm_bench.py not found at ${GUIDELLM_SCRIPT} — copy manually"
fi

info "Copying scripts/ modules into the pod..."
oc exec benchmark-runner -n "${PERF_NAMESPACE}" -- mkdir -p /scripts/scripts

for SCRIPT_FILE in log_guidellm_to_mlflow.py prom_collector.py; do
  SRC="${SCRIPT_DIR}/scripts/${SCRIPT_FILE}"
  if [[ -f "$SRC" ]]; then
    oc cp "$SRC" "${PERF_NAMESPACE}/benchmark-runner:/scripts/scripts/${SCRIPT_FILE}"
    ok "  ${SCRIPT_FILE} → /scripts/scripts/"
  else
    warn "  ${SCRIPT_FILE} not found at ${SRC}"
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. VERIFY POD PLACEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RUNNER_NODE=$(oc get pod benchmark-runner -n "${PERF_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
RUNNER_INSTANCE=$(oc get node "${RUNNER_NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")

if [[ "$RUNNER_INSTANCE" == "${LOADGEN_WORKER_INSTANCE_TYPE}" ]]; then
  ok "benchmark-runner is on load-gen worker (${RUNNER_NODE}, ${RUNNER_INSTANCE})"
else
  warn "benchmark-runner is on ${RUNNER_NODE} (${RUNNER_INSTANCE}) — expected ${LOADGEN_WORKER_INSTANCE_TYPE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USAGE INFO
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "============================================"
echo "  Benchmark Runner Ready"
echo "============================================"
echo ""
info "GuideLLM benchmarks (results logged to MLflow automatically):"
echo "  # Phase 1 — Direct baseline"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/run_guidellm_bench.py --method direct --sim-profile fast --payload small"
echo ""
echo "  # Phase 2 — OGX Chat-Completion"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/run_guidellm_bench.py --method chat --sim-profile fast --payload all"
echo ""
echo "  # Phase 3 — OGX Response API"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/run_guidellm_bench.py --method response --sim-profile fast --payload all"
echo ""
echo "  # Quick smoke test"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/run_guidellm_bench.py --method chat --sim-profile fast --quick"
echo ""
echo "  # Skip MLflow logging"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/run_guidellm_bench.py --method chat --sim-profile fast --no-mlflow"
echo ""
info "MLflow: experiments named OGX-<method>-<sim-profile> (e.g. OGX-chat-fast)"
echo "  Tracking URI: ${MLFLOW_TRACKING_URI}"
echo "  Workspace:    ${MLFLOW_WORKSPACE}"
echo ""
info "Legacy load test:"
echo "  oc exec benchmark-runner -n ${PERF_NAMESPACE} -- python3 /scripts/06-load-test.py"
echo ""
info "Or connect interactively:"
echo "  oc exec -it benchmark-runner -n ${PERF_NAMESPACE} -- bash"
echo ""
info "Copy results out when done:"
echo "  oc cp ${PERF_NAMESPACE}/benchmark-runner:/results ./benchmark-results-\$(date +%Y%m%d)"
echo ""
ok "Setup complete. Happy benchmarking!"

