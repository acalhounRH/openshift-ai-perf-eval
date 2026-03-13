#!/usr/bin/env bash
# ============================================================================
# 02-label-nodes.sh — Label and taint worker nodes for role-based scheduling
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Labeling & Tainting Worker Nodes"
echo "============================================"
echo ""

# ─── Verify connectivity ───────────────────────────────────────────────────
oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"
ok "Connected to cluster as $(oc whoami)"

# ─── Show current nodes ──────────────────────────────────────────────────
info "Current node list:"
oc get nodes -o wide
echo ""

# ─── Identify nodes by instance type ────────────────────────────────────
# On IBM Cloud IPI, nodes are labeled with node.kubernetes.io/instance-type
# matching the VPC profile name.

# App worker: bx2-4x16 with worker role (not a master)
APP_NODE=$(oc get nodes \
  -l "node.kubernetes.io/instance-type=${APP_WORKER_INSTANCE_TYPE},node-role.kubernetes.io/worker" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

# Inference worker: identified by GPU/inference instance type
INFERENCE_NODE=$(oc get nodes \
  -l "node.kubernetes.io/instance-type=${INFERENCE_WORKER_INSTANCE_TYPE}" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

# Load-gen worker: identified by its instance type
LOADGEN_NODE=$(oc get nodes \
  -l "node.kubernetes.io/instance-type=${LOADGEN_WORKER_INSTANCE_TYPE}" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

# ─── Validate detection ──────────────────────────────────────────────────
[[ -n "$APP_NODE" ]]     || bail "Could not find app worker node (${APP_WORKER_INSTANCE_TYPE})"
[[ -n "$INFERENCE_NODE" ]] || bail "Could not find inference worker node (${INFERENCE_WORKER_INSTANCE_TYPE})"
[[ -n "$LOADGEN_NODE" ]] || bail "Could not find load-gen worker node (${LOADGEN_WORKER_INSTANCE_TYPE})"

info "Detected nodes:"
info "  App worker:      ${APP_NODE}"
info "  Inference worker: ${INFERENCE_NODE}"
info "  Load-gen worker: ${LOADGEN_NODE}"
echo ""

# ─── Label app worker ──────────────────────────────────────────────────────
info "Labeling app worker..."
oc label node "${APP_NODE}" node-role.kubernetes.io/app-worker="" --overwrite
ok "App worker labeled: node-role.kubernetes.io/app-worker"

# ─── Label load-gen worker ────────────────────────────────────────────────
info "Labeling load-gen worker..."
oc label node "${LOADGEN_NODE}" node-role.kubernetes.io/loadgen-worker="" --overwrite
ok "Load-gen worker labeled: node-role.kubernetes.io/loadgen-worker"

# ─── Label inference worker ──────────────────────────────────────────────
# The GPU taint is applied in 03-install-operators.sh after the GPU Operator
# is installed and GPUs are detected. Here we just label for identification.
info "Labeling inference worker..."
oc label node "${INFERENCE_NODE}" node-role.kubernetes.io/inference-worker="" --overwrite
ok "Inference worker labeled: node-role.kubernetes.io/inference-worker"

# ─── Verify ───────────────────────────────────────────────────────────────
echo ""
info "Verifying labels..."
oc get nodes -L node-role.kubernetes.io/app-worker,node-role.kubernetes.io/inference-worker,node-role.kubernetes.io/loadgen-worker \
  --no-headers | while read -r line; do
  echo "  $line"
done

echo ""
ok "Node labeling complete."
echo ""
info "Next step: ./03-install-operators.sh"

