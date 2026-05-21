#!/usr/bin/env bash
# ============================================================================
# scale-up.sh — Scale GPU + load-gen workers to 1 (start test session)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Scaling Up GPU + Load-Gen Workers"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"

# Find MachineSet names
GPU_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i inference || echo "")
LOADGEN_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i loadgen || echo "")

[[ -n "$GPU_MS" ]]     || bail "Could not find GPU MachineSet. List: oc get machineset -n openshift-machine-api"
[[ -n "$LOADGEN_MS" ]] || bail "Could not find load-gen MachineSet. List: oc get machineset -n openshift-machine-api"

info "GPU MachineSet:      ${GPU_MS}"
info "Load-gen MachineSet: ${LOADGEN_MS}"
echo ""

# Scale up
info "Scaling GPU worker to 1..."
oc scale machineset "${GPU_MS}" -n openshift-machine-api --replicas=1
ok "GPU MachineSet scaled to 1"

info "Scaling load-gen worker to 1..."
oc scale machineset "${LOADGEN_MS}" -n openshift-machine-api --replicas=1
ok "Load-gen MachineSet scaled to 1"

echo ""
info "Current machines:"
oc get machines -n openshift-machine-api --no-headers | awk '{printf "  %-50s %s\n", $1, $2}'
echo ""
info "Waiting for nodes to be Ready..."
info "  GPU node:     ~5-10 min (instance + GPU driver install)"
info "  Load-gen node: ~3-5 min"
info "  App worker:   already running — Llama Stack/PostgreSQL immediately available"
echo ""
info "Note: IBM Cloud VPC Block Storage is network-attached."
info "Cold-start model loading will take 2-5 min for 70B (vs. seconds from NVMe)."
echo ""
info "Monitor: oc get nodes -w"
