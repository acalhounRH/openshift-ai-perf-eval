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

# ─── Identify nodes by MachineSet membership ────────────────────────────
# IBM Cloud IPI creates named worker pools in install-config. We match nodes
# to their MachineSet via the machine.openshift.io/cluster-api-machineset label
# on the Machine objects, then map Machine → Node.

node_from_machineset() {
  local ms_pattern="$1"
  local machine
  machine=$(oc get machines -n openshift-machine-api -o json 2>/dev/null \
    | jq -r ".items[] | select(.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] | test(\"${ms_pattern}\")) | .status.nodeRef.name" \
    | head -1)
  echo "$machine"
}

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')

APP_NODE=$(node_from_machineset "${INFRA_ID}.*app-worker")
INFERENCE_NODE=$(node_from_machineset "${INFRA_ID}.*inference-worker")
TOOLS_NODE=$(node_from_machineset "${INFRA_ID}.*tools-worker")
RAG_NODE=$(node_from_machineset "${INFRA_ID}.*rag-worker")
LOADGEN_NODE=$(node_from_machineset "${INFRA_ID}.*loadgen-worker")

# ─── Validate detection ──────────────────────────────────────────────────
[[ -n "$APP_NODE" ]]       || bail "Could not find app worker node"
[[ -n "$INFERENCE_NODE" ]] || bail "Could not find inference worker node"
[[ -n "$TOOLS_NODE" ]]    || bail "Could not find tools worker node"
[[ -n "$RAG_NODE" ]]      || bail "Could not find RAG worker node"
[[ -n "$LOADGEN_NODE" ]]  || bail "Could not find load-gen worker node"

info "Detected nodes:"
info "  App worker:       ${APP_NODE}"
info "  Inference worker: ${INFERENCE_NODE}"
info "  Tools worker:     ${TOOLS_NODE}"
info "  RAG worker:       ${RAG_NODE}"
info "  Load-gen worker:  ${LOADGEN_NODE}"
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
info "Labeling inference worker..."
oc label node "${INFERENCE_NODE}" node-role.kubernetes.io/inference-worker="" --overwrite
ok "Inference worker labeled: node-role.kubernetes.io/inference-worker"

# ─── Label tools worker ─────────────────────────────────────────────────
info "Labeling tools worker..."
oc label node "${TOOLS_NODE}" node-role.kubernetes.io/tools-worker="" --overwrite
ok "Tools worker labeled: node-role.kubernetes.io/tools-worker"

# ─── Label RAG worker ───────────────────────────────────────────────────
info "Labeling RAG worker..."
oc label node "${RAG_NODE}" node-role.kubernetes.io/rag-worker="" --overwrite
ok "RAG worker labeled: node-role.kubernetes.io/rag-worker"

# ─── Verify ───────────────────────────────────────────────────────────────
echo ""
info "Verifying labels..."
oc get nodes -L node-role.kubernetes.io/app-worker,node-role.kubernetes.io/inference-worker,node-role.kubernetes.io/tools-worker,node-role.kubernetes.io/rag-worker,node-role.kubernetes.io/loadgen-worker \
  --no-headers | while read -r line; do
  echo "  $line"
done

echo ""
ok "Node labeling complete."
echo ""
info "Next step: ./03-install-operators.sh"

