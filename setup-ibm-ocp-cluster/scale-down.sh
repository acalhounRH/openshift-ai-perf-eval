#!/usr/bin/env bash
# ============================================================================
# scale-down.sh — Scale GPU + load-gen workers to 0 (end test session, save $)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Scaling Down GPU + Load-Gen Workers"
echo "  App worker stays running (PostgreSQL/Llama Stack persist)"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"

# Find MachineSet names
GPU_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i inference || echo "")
LOADGEN_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i loadgen || echo "")

[[ -n "$GPU_MS" ]]     || bail "Could not find GPU MachineSet."
[[ -n "$LOADGEN_MS" ]] || bail "Could not find load-gen MachineSet."

info "GPU MachineSet:      ${GPU_MS}"
info "Load-gen MachineSet: ${LOADGEN_MS}"
echo ""

# Scale down
info "Scaling GPU worker to 0..."
oc scale machineset "${GPU_MS}" -n openshift-machine-api --replicas=0
ok "GPU MachineSet scaled to 0"

info "Scaling load-gen worker to 0..."
oc scale machineset "${LOADGEN_MS}" -n openshift-machine-api --replicas=0
ok "Load-gen MachineSet scaled to 0"

echo ""
info "Nodes will drain and terminate in a few minutes."
info "VPC Block Storage volumes persist — data is not lost."
info "App worker stays running — Llama Stack/PostgreSQL remain available."
echo ""
info "Current machines:"
oc get machines -n openshift-machine-api --no-headers | awk '{printf "  %-50s %s\n", $1, $2}'
echo ""
info "To resume testing later: ./scale-up.sh"
