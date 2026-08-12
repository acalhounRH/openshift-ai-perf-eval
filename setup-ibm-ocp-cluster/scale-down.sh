#!/usr/bin/env bash
# ============================================================================
# scale-down.sh — Scale all worker MachineSets to 0 (end test session, save $)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Scaling Down All Workers"
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

info "Scaling OGX worker to 0..."
oc scale machineset "${OGX_MS}" -n openshift-machine-api --replicas=0
ok "OGX MachineSet scaled to 0"

info "Scaling PostgreSQL worker to 0..."
oc scale machineset "${POSTGRES_MS}" -n openshift-machine-api --replicas=0
ok "PostgreSQL MachineSet scaled to 0"

info "Scaling loadgen worker to 0..."
oc scale machineset "${LOADGEN_MS}" -n openshift-machine-api --replicas=0
ok "Loadgen MachineSet scaled to 0"

echo ""
info "Nodes will drain and terminate in a few minutes."
info "VPC Block Storage volumes persist — data is not lost."
echo ""
info "Current machines:"
oc get machines -n openshift-machine-api --no-headers | awk '{printf "  %-50s %s\n", $1, $2}'
echo ""
info "To resume testing later: ./scale-up.sh"
