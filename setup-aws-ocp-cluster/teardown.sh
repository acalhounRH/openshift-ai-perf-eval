#!/usr/bin/env bash
# ============================================================================
# teardown.sh — Destroy the entire cluster and clean up AWS resources
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  ⚠  CLUSTER TEARDOWN"
echo "  Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  Region:  ${AWS_REGION}"
echo "============================================"
echo ""
warn "This will DESTROY the entire cluster and all data."
warn "EBS volumes, EC2 instances, load balancers — everything."
echo ""

if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  info "Auto-confirmed via --yes flag"
else
  read -rp "Type the cluster name to confirm (${CLUSTER_NAME}): " confirm
  if [[ "$confirm" != "${CLUSTER_NAME}" ]]; then
    err "Confirmation failed. Aborting."
    exit 1
  fi
fi

echo ""

# ─── Export benchmark results before destroying ─────────────────────────────
info "Checking for benchmark results to export..."
if oc get pod benchmark-runner -n "${PERF_NAMESPACE}" >/dev/null 2>&1; then
  EXPORT_DIR="${SCRIPT_DIR}/../benchmark-results-$(date +%Y%m%d-%H%M%S)"
  info "Exporting results to ${EXPORT_DIR}..."
  mkdir -p "${EXPORT_DIR}"
  oc cp "${PERF_NAMESPACE}/benchmark-runner:/results" "${EXPORT_DIR}/" 2>/dev/null && \
    ok "Results exported to ${EXPORT_DIR}" || \
    warn "Could not export results — pod may not be running"
else
  warn "No benchmark-runner pod found. Skipping export."
fi

# ─── Destroy cluster ───────────────────────────────────────────────────────
if [[ -d "${INSTALLER_DIR}" ]]; then
  info "Destroying cluster using installer directory: ${INSTALLER_DIR}"
  openshift-install destroy cluster --dir="${INSTALLER_DIR}" --log-level=info
  ok "Cluster destroyed"
else
  warn "Installer directory not found: ${INSTALLER_DIR}"
  warn "Cannot auto-destroy. Check the AWS console for leftover resources."
  warn "Look for resources tagged: kubernetes.io/cluster/${CLUSTER_NAME}"
fi

echo ""
ok "Teardown complete."
info "Check your AWS console to verify all resources are gone."
info "Especially: EC2 instances, EBS volumes, ELBs, Route 53 records, VPCs."

