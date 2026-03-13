#!/usr/bin/env bash
# ============================================================================
# 00-prereqs.sh — Verify prerequisites before cluster installation
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Prerequisite Check (Self-Managed OCP on IBM Cloud)"
echo "  Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  Region:  ${IBMCLOUD_REGION} / ${IBMCLOUD_ZONE}"
echo "============================================"
echo ""

PASS=0
FAIL=0

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

# ─── CLI Tools ──────────────────────────────────────────────────────────────
info "Checking CLI tools..."
check "openshift-install is installed"   command -v openshift-install
check "oc CLI is installed"              command -v oc
check "kubectl is installed"             command -v kubectl
check "ibmcloud CLI is installed"        command -v ibmcloud
check "jq is installed"                  command -v jq
check "yq is installed (optional)"       command -v yq || warn "yq not found — optional but helpful"

# ─── IBM Cloud CLI Plugins ─────────────────────────────────────────────────
info "Checking IBM Cloud CLI plugins..."

check_plugin() {
  local plugin="$1"
  ibmcloud plugin list 2>/dev/null | grep -qi "$plugin"
}

check "vpc-infrastructure plugin installed" check_plugin "vpc-infrastructure"

# ─── IBM Cloud API Key ─────────────────────────────────────────────────────
info "Checking IBM Cloud API key..."
if [[ -n "${IC_API_KEY}" ]]; then
  ok "IC_API_KEY environment variable is set"
  PASS=$((PASS + 1))
else
  err "IC_API_KEY environment variable is NOT set"
  warn "openshift-install requires IC_API_KEY to provision IBM Cloud resources"
  warn "Set with: export IC_API_KEY=<your-ibm-cloud-api-key>"
  FAIL=$((FAIL + 1))
fi

# ─── IBM Cloud Login ──────────────────────────────────────────────────────
info "Checking IBM Cloud login..."
if ibmcloud target 2>/dev/null | grep -q "Region:"; then
  ok "IBM Cloud CLI is logged in"
  PASS=$((PASS + 1))

  ACCOUNT_NAME=$(ibmcloud target 2>/dev/null | grep "Account:" | sed 's/Account: *//' || echo "unknown")
  CURRENT_REGION=$(ibmcloud target 2>/dev/null | grep "Region:" | sed 's/Region: *//' || echo "unknown")
  info "  Account: ${ACCOUNT_NAME}"
  info "  Region:  ${CURRENT_REGION}"
else
  err "IBM Cloud CLI is not logged in"
  warn "Run: ibmcloud login --apikey \$IC_API_KEY"
  FAIL=$((FAIL + 1))
fi

# ─── IBM Cloud CIS (DNS) ──────────────────────────────────────────────────
info "Checking IBM Cloud Internet Services (CIS) for DNS zone: ${BASE_DOMAIN}..."
CIS_INSTANCES=$(ibmcloud cis instances 2>/dev/null | grep -c "active" || echo "0")
if [[ "$CIS_INSTANCES" -ge 1 ]]; then
  ok "At least one active CIS instance found"
  PASS=$((PASS + 1))
  info "  Verify that ${BASE_DOMAIN} is configured in your CIS instance."
  info "  openshift-install creates DNS records in CIS automatically."
else
  err "No active CIS (Cloud Internet Services) instances found"
  warn "openshift-install requires CIS for DNS management of ${BASE_DOMAIN}"
  warn "Create CIS: ibmcloud cis instance-create <name> standard-next"
  warn "Then add your domain: ibmcloud cis domain-add ${BASE_DOMAIN} -i <cis-instance>"
  FAIL=$((FAIL + 1))
fi

# ─── GPU Profile Availability ──────────────────────────────────────────────
info "Checking VPC instance profile availability..."

check_profile() {
  local profile="$1"
  ibmcloud is instance-profiles 2>/dev/null | grep -q "${profile}"
}

check "${GPU_WORKER_INSTANCE_TYPE} profile available"    check_profile "${GPU_WORKER_INSTANCE_TYPE}"
check "${APP_WORKER_INSTANCE_TYPE} profile available"    check_profile "${APP_WORKER_INSTANCE_TYPE}"
check "${LOADGEN_WORKER_INSTANCE_TYPE} profile available" check_profile "${LOADGEN_WORKER_INSTANCE_TYPE}"
check "${MASTER_INSTANCE_TYPE} profile available"        check_profile "${MASTER_INSTANCE_TYPE}"

# ─── GPU Quota Check ──────────────────────────────────────────────────────
info "Checking GPU instance quota..."
GPU_FAMILY="${GPU_WORKER_INSTANCE_TYPE%%-*}"          # e.g. gx3 from gx3-64x320x4l40s
GPU_QUOTA_CHECK=$(ibmcloud is instance-profiles 2>/dev/null | grep -c "${GPU_FAMILY}" || echo "0")
if [[ "$GPU_QUOTA_CHECK" -ge 1 ]]; then
  ok "GPU instance profiles (${GPU_FAMILY}) are available in this region"
  PASS=$((PASS + 1))
  info "  Note: GPU instances may require explicit quota approval."
  info "  Check: https://cloud.ibm.com/docs/vpc?topic=vpc-quotas"
else
  warn "No ${GPU_FAMILY} GPU profiles found. GPU instances may not be available in ${IBMCLOUD_REGION}."
  warn "Submit a quota request if needed."
  FAIL=$((FAIL + 1))
fi

# ─── Files ──────────────────────────────────────────────────────────────────
info "Checking required files..."
check "Pull secret file exists: ${PULL_SECRET_FILE}"  test -f "${PULL_SECRET_FILE}"
check "SSH public key exists: ${SSH_PUBLIC_KEY_FILE}" test -f "${SSH_PUBLIC_KEY_FILE}"

if [[ -f "${PULL_SECRET_FILE}" ]]; then
  check "Pull secret is valid JSON" jq empty "${PULL_SECRET_FILE}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  err "Fix the above issues before running 01-install-cluster.sh"
  echo ""
  info "Common fixes:"
  info "  - Install openshift-install:  Download from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
  info "  - Install IBM Cloud CLI:      curl -fsSL https://clis.cloud.ibm.com/install/linux | sh"
  info "  - Install VPC plugin:         ibmcloud plugin install vpc-infrastructure"
  info "  - Set API key:                export IC_API_KEY=<your-api-key>"
  info "  - Log in:                     ibmcloud login --apikey \$IC_API_KEY -r ${IBMCLOUD_REGION}"
  info "  - Create CIS instance:        ibmcloud cis instance-create perf-eval-cis standard-next"
  info "  - Get pull secret:            https://console.redhat.com/openshift/install/pull-secret"
  info "  - Request GPU quota:          https://cloud.ibm.com/unifiedsupport/cases/form"
  exit 1
else
  echo ""
  ok "All prerequisites met. Ready to install."
  echo ""
  info "Next step: ./01-install-cluster.sh"
fi
