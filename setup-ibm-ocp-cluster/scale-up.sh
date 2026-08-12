#!/usr/bin/env bash
# ============================================================================
# scale-up.sh — Scale all worker MachineSets to 1 (start test session)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Scaling Up All Workers"
echo "  OGX + PostgreSQL + Loadgen/Simulator"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"

OGX_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i ogx || echo "")
POSTGRES_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i postgres || echo "")
LOADGEN_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':metadata.name' | grep -i loadgen || echo "")

[[ -n "$OGX_MS" ]]      || bail "Could not find OGX MachineSet."
[[ -n "$POSTGRES_MS" ]]  || bail "Could not find PostgreSQL MachineSet."
[[ -n "$LOADGEN_MS" ]]   || bail "Could not find loadgen MachineSet."

info "OGX MachineSet:        ${OGX_MS}"
info "PostgreSQL MachineSet: ${POSTGRES_MS}"
info "Loadgen MachineSet:    ${LOADGEN_MS}"
echo ""

info "Scaling OGX worker to 1..."
oc scale machineset "${OGX_MS}" -n openshift-machine-api --replicas=1
ok "OGX MachineSet scaled to 1"

info "Scaling PostgreSQL worker to 1..."
oc scale machineset "${POSTGRES_MS}" -n openshift-machine-api --replicas=1
ok "PostgreSQL MachineSet scaled to 1"

info "Scaling loadgen worker to 1..."
oc scale machineset "${LOADGEN_MS}" -n openshift-machine-api --replicas=1
ok "Loadgen MachineSet scaled to 1"

echo ""
info "Current machines:"
oc get machines -n openshift-machine-api --no-headers | awk '{printf "  %-50s %s\n", $1, $2}'
echo ""
info "Waiting for nodes to be Ready (~3-5 min per node)..."
echo ""
info "Monitor: oc get nodes -w"
