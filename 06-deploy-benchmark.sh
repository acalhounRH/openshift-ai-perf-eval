#!/usr/bin/env bash
# ============================================================================
# 06-deploy-benchmark.sh — Deploy the benchmark runner pod on the load-gen worker
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

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
    image: ${BENCHMARK_RUNNER_IMAGE}
    command: ["sleep", "infinity"]
    env:
    - name: LLAMA_STACK_URL
      value: "http://llama-stack:8321"
    - name: VLLM_URL
      value: "http://vllm-inference:8000"
    - name: MODEL_ID
      value: "${MODEL_ID}"
    - name: PERF_NAMESPACE
      value: "${PERF_NAMESPACE}"
    resources:
      requests:
        cpu: "${BENCHMARK_RUNNER_CPU_REQUEST}"
        memory: "${BENCHMARK_RUNNER_MEM_REQUEST}"
      limits:
        cpu: "${BENCHMARK_RUNNER_CPU_LIMIT}"
        memory: "${BENCHMARK_RUNNER_MEM_LIMIT}"
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
  pip install --quiet --no-cache-dir \
    vllm \
    openai \
    aiohttp \
    locust \
    llama-stack-client \
    requests \
    numpy \
    2>&1 | tail -1
'

ok "Benchmark tools installed"

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
info "Connect to the benchmark pod:"
echo "  oc exec -it benchmark-runner -n ${PERF_NAMESPACE} -- bash"
echo ""
info "Run vLLM benchmark (raw inference):"
echo "  python -m vllm.benchmark_serving \\"
echo "    --backend openai \\"
echo "    --base-url \$VLLM_URL \\"
echo "    --model \$MODEL_ID \\"
echo "    --dataset-name sharegpt \\"
echo "    --num-prompts 200 \\"
echo "    --request-rate 2 \\"
echo "    --seed 42"
echo ""
info "Copy results out when done:"
echo "  oc cp ${PERF_NAMESPACE}/benchmark-runner:/results ./benchmark-results-\$(date +%Y%m%d)"
echo ""
info "Copy custom scripts into the pod:"
echo "  oc cp my-benchmark.py ${PERF_NAMESPACE}/benchmark-runner:/scripts/"
echo ""
ok "Setup complete. Happy benchmarking!"

