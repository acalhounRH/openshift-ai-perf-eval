#!/usr/bin/env bash
# ============================================================================
# 00-prereqs.sh — Verify prerequisites before cluster installation
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

PASS=0
FAIL=0
WARN=0

pass() {
  echo -e "  ${GREEN}✔ PASS${NC}  $*"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}✘ FAIL${NC}  $*"
  FAIL=$((FAIL + 1))
}

skip() {
  echo -e "  ${YELLOW}⚠ WARN${NC}  $*"
  WARN=$((WARN + 1))
}

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

echo ""
echo "============================================"
echo "  Prerequisite Check"
echo "  Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  Region:  ${AWS_REGION} / ${AWS_ZONE}"
echo "============================================"

# ─── CLI Tools ──────────────────────────────────────────────────────────────
echo ""
info "CLI tools"
echo "  ────────────────────────────────────────"
check "openshift-install is installed"   command -v openshift-install

if command -v openshift-install >/dev/null 2>&1; then
  INSTALLER_VER=$(openshift-install version 2>/dev/null | head -1 | awk '{print $2}')
  echo -e "         Version: ${INSTALLER_VER}"
  EXPECTED_MINOR=$(echo "${OCP_VERSION}" | grep -oE '[0-9]+\.[0-9]+' || echo "")
  ACTUAL_MINOR=$(echo "${INSTALLER_VER}" | grep -oE '^[0-9]+\.[0-9]+' || echo "")
  if [[ -n "$EXPECTED_MINOR" && -n "$ACTUAL_MINOR" && "$EXPECTED_MINOR" != "$ACTUAL_MINOR" ]]; then
    fail "openshift-install ${ACTUAL_MINOR} does not match OCP_VERSION ${OCP_VERSION} — download the ${EXPECTED_MINOR} binary"
    echo -e "         Download: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/"
  elif [[ -n "$EXPECTED_MINOR" ]]; then
    pass "openshift-install version matches OCP_VERSION (${ACTUAL_MINOR})"
  fi
fi

check "oc CLI is installed"              command -v oc
check "kubectl is installed"             command -v kubectl
check "aws CLI is installed"             command -v aws
check "jq is installed"                  command -v jq

if command -v yq >/dev/null 2>&1; then
  pass "yq is installed (optional)"
else
  skip "yq not found — optional but helpful"
fi

# ─── AWS Credentials ────────────────────────────────────────────────────────
echo ""
info "AWS credentials"
echo "  ────────────────────────────────────────"

if aws sts get-caller-identity >/dev/null 2>&1; then
  pass "AWS credentials are configured"
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
  AWS_IDENTITY=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown")
  echo -e "         Account:  ${AWS_ACCOUNT}"
  echo -e "         Identity: ${AWS_IDENTITY}"
else
  fail "AWS credentials are configured"
fi

# ─── AWS Region Availability ────────────────────────────────────────────────
echo ""
info "Instance type availability in ${AWS_REGION} / ${AWS_ZONE}"
echo "  ────────────────────────────────────────"

check_instance_type() {
  local itype="$1"
  local zone="$2"
  aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=${itype}" "Name=location,Values=${zone}" \
    --region "${AWS_REGION}" \
    --query "InstanceTypeOfferings[0].InstanceType" \
    --output text 2>/dev/null | grep -q "${itype}"
}

check "${MASTER_INSTANCE_TYPE} available in ${AWS_ZONE}"          check_instance_type "${MASTER_INSTANCE_TYPE}" "${AWS_ZONE}"
check "${APP_WORKER_INSTANCE_TYPE} available in ${AWS_ZONE}"      check_instance_type "${APP_WORKER_INSTANCE_TYPE}" "${AWS_ZONE}"
check "${GPU_WORKER_INSTANCE_TYPE} available in ${AWS_ZONE}"      check_instance_type "${GPU_WORKER_INSTANCE_TYPE}" "${AWS_ZONE}"
check "${LOADGEN_WORKER_INSTANCE_TYPE} available in ${AWS_ZONE}"  check_instance_type "${LOADGEN_WORKER_INSTANCE_TYPE}" "${AWS_ZONE}"

# ─── GPU Quota Check ────────────────────────────────────────────────────────
echo ""

GPU_FAMILY="${GPU_WORKER_INSTANCE_TYPE%%.*}"
GPU_VCPU=$(aws ec2 describe-instance-types \
  --instance-types "${GPU_WORKER_INSTANCE_TYPE}" \
  --query "InstanceTypes[0].VCpuInfo.DefaultVCpus" \
  --output text --region "${AWS_REGION}" 2>/dev/null || echo "96")

case "${GPU_FAMILY}" in
  g5|g5g|g6)  QUOTA_CODE="L-DB2E81BA"; FAMILY_LABEL="G and VT" ;;
  p4d|p4de)   QUOTA_CODE="L-417A185B"; FAMILY_LABEL="P" ;;
  p5*)        QUOTA_CODE="L-417A185B"; FAMILY_LABEL="P" ;;
  *)          QUOTA_CODE=""; FAMILY_LABEL="unknown" ;;
esac

info "GPU instance quota (${GPU_FAMILY} → ${FAMILY_LABEL} family, needs ${GPU_VCPU} vCPUs)"
echo "  ────────────────────────────────────────"

if [[ -n "$QUOTA_CODE" ]]; then
  GPU_QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code "${QUOTA_CODE}" \
    --region "${AWS_REGION}" \
    --query "Quota.Value" \
    --output text 2>/dev/null || echo "unknown")

  if [[ "$GPU_QUOTA" != "unknown" ]]; then
    echo -e "         Current quota: ${GPU_QUOTA} vCPUs"
    if (( $(echo "$GPU_QUOTA >= $GPU_VCPU" | bc -l 2>/dev/null || echo 0) )); then
      pass "${FAMILY_LABEL} instance quota sufficient (${GPU_QUOTA} >= ${GPU_VCPU} vCPUs needed for ${GPU_WORKER_INSTANCE_TYPE})"
    else
      fail "${FAMILY_LABEL} instance quota too low (${GPU_QUOTA} < ${GPU_VCPU} vCPUs) — request increase via AWS console"
    fi
  else
    skip "Could not check GPU quota — verify manually that you have ≥${GPU_VCPU} vCPU for ${FAMILY_LABEL} instances"
  fi
else
  skip "Unknown GPU family '${GPU_FAMILY}' — verify quota manually for ${GPU_WORKER_INSTANCE_TYPE}"
fi

# ─── Files ──────────────────────────────────────────────────────────────────
echo ""
info "Required files"
echo "  ────────────────────────────────────────"

check "Pull secret file exists: ${PULL_SECRET_FILE}"   test -f "${PULL_SECRET_FILE}"
check "SSH public key exists: ${SSH_PUBLIC_KEY_FILE}"   test -f "${SSH_PUBLIC_KEY_FILE}"

if [[ -f "${PULL_SECRET_FILE}" ]]; then
  check "Pull secret is valid JSON" jq empty "${PULL_SECRET_FILE}"
fi

# ─── Route 53 Hosted Zone ──────────────────────────────────────────────────
echo ""
info "Route 53 hosted zone for ${BASE_DOMAIN}"
echo "  ────────────────────────────────────────"

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${BASE_DOMAIN}" \
  --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" \
  --output text 2>/dev/null || echo "")

if [[ -n "$ZONE_ID" ]]; then
  pass "Route 53 hosted zone found: ${ZONE_ID}"
else
  fail "No Route 53 hosted zone found for ${BASE_DOMAIN}"
  echo -e "         Create one: aws route53 create-hosted-zone --name ${BASE_DOMAIN} --caller-reference \$(date +%s)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo -e "  ${GREEN}✔ ${PASS} passed${NC}    ${RED}✘ ${FAIL} failed${NC}    ${YELLOW}⚠ ${WARN} warnings${NC}"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  err "Fix the above failures before running 01-install-cluster.sh"
  exit 1
else
  echo ""
  ok "All prerequisites met. Ready to install."
  echo ""
  info "Next step: ./01-install-cluster.sh"
fi
