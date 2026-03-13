#!/usr/bin/env bash
# ============================================================================
# 01-install-cluster.sh — Generate install-config.yaml and install the OCP cluster
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Installing OCP Cluster"
echo "  Name:   ${CLUSTER_NAME}"
echo "  Domain: ${BASE_DOMAIN}"
echo "  Region: ${AWS_REGION} / ${AWS_ZONE}"
echo "============================================"
echo ""

# ─── Read secrets ───────────────────────────────────────────────────────────
PULL_SECRET=$(cat "${PULL_SECRET_FILE}")
SSH_KEY=$(cat "${SSH_PUBLIC_KEY_FILE}")

# ─── Create installer directory ─────────────────────────────────────────────
if [[ -d "${INSTALLER_DIR}" ]]; then
  warn "Installer directory already exists: ${INSTALLER_DIR}"
  read -rp "Delete and recreate? (y/N) " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -rf "${INSTALLER_DIR}"
  else
    bail "Aborting. Remove or rename ${INSTALLER_DIR} and try again."
  fi
fi

mkdir -p "${INSTALLER_DIR}"
info "Installer directory: ${INSTALLER_DIR}"

# ─── Generate install-config.yaml ───────────────────────────────────────────
info "Generating install-config.yaml..."

cat > "${INSTALLER_DIR}/install-config.yaml" <<YAML
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${AWS_REGION}
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: ${MASTER_INSTANCE_TYPE}
      zones:
        - ${AWS_ZONE}
      rootVolume:
        size: ${MASTER_ROOT_VOLUME_SIZE}
        type: ${ROOT_VOLUME_TYPE}
        iops: ${MASTER_ROOT_VOLUME_IOPS}
compute:
  - name: worker
    replicas: 1
    platform:
      aws:
        type: ${APP_WORKER_INSTANCE_TYPE}
        zones:
          - ${AWS_ZONE}
        rootVolume:
          size: ${APP_WORKER_ROOT_VOLUME_SIZE}
          type: ${ROOT_VOLUME_TYPE}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
YAML

ok "install-config.yaml generated"

# ─── Save a backup (openshift-install consumes the file) ────────────────────
cp "${INSTALLER_DIR}/install-config.yaml" "${INSTALLER_DIR}/install-config.yaml.bak"
info "Backup saved to install-config.yaml.bak"

# ─── Create manifests ──────────────────────────────────────────────────────
info "Creating manifests..."
openshift-install create manifests --dir="${INSTALLER_DIR}" --log-level=info

# ─── Set masters to NOT schedulable ─────────────────────────────────────────
SCHEDULER_CONFIG="${INSTALLER_DIR}/manifests/cluster-scheduler-02-config.yml"
if [[ -f "$SCHEDULER_CONFIG" ]]; then
  info "Setting mastersSchedulable: false..."
  if command -v sed >/dev/null; then
    # macOS-compatible sed
    if sed --version 2>/dev/null | grep -q GNU; then
      sed -i 's/mastersSchedulable: true/mastersSchedulable: false/' "$SCHEDULER_CONFIG"
    else
      sed -i '' 's/mastersSchedulable: true/mastersSchedulable: false/' "$SCHEDULER_CONFIG"
    fi
    ok "Masters set to non-schedulable"
  else
    warn "sed not found. Manually edit ${SCHEDULER_CONFIG} to set mastersSchedulable: false"
  fi
else
  warn "Scheduler config not found at expected path. Check manifests directory."
fi

# ─── Install the cluster ───────────────────────────────────────────────────
echo ""
info "Starting cluster installation (~35-45 minutes)..."
info "Logs: ${INSTALLER_DIR}/.openshift_install.log"
echo ""

INSTALL_EXIT=0
openshift-install create cluster --dir="${INSTALLER_DIR}" --log-level=info || INSTALL_EXIT=$?

export KUBECONFIG="${INSTALLER_DIR}/auth/kubeconfig"

if [[ $INSTALL_EXIT -ne 0 ]]; then
  warn "openshift-install exited with code ${INSTALL_EXIT}"
  warn "Checking if the cluster is actually functional despite the error..."
  if oc whoami >/dev/null 2>&1; then
    ok "Cluster API is reachable — likely a cosmetic bootstrap cleanup failure"
  else
    bail "Cluster API is NOT reachable. Installation failed. Check ${INSTALLER_DIR}/.openshift_install.log"
  fi
fi

# ─── Fix AWS security group tags (bootstrap cleanup failure workaround) ────
# The CAPI bootstrap cleanup on OCP 4.20 often times out, leaving multiple
# security groups tagged with kubernetes.io/cluster/<infra-id>. This prevents
# the ingress LoadBalancer from being created, which blocks auth/console COs
# and ultimately the ClusterVersion from completing.
info "Checking for duplicate AWS security group tags..."
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
if [[ -n "$INFRA_ID" ]]; then
  NODE_SG=$(aws ec2 describe-security-groups \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
              "Name=group-name,Values=*-node" \
    --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || echo "")

  ALL_TAGGED=$(aws ec2 describe-security-groups \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
    --query 'SecurityGroups[*].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || echo "")

  for sg in $ALL_TAGGED; do
    if [[ "$sg" != "$NODE_SG" && -n "$NODE_SG" ]]; then
      info "Removing cluster tag from extra SG: $sg"
      aws ec2 delete-tags --resources "$sg" \
        --tags "Key=kubernetes.io/cluster/${INFRA_ID}" \
        --region "${AWS_REGION}" 2>/dev/null || true
    fi
  done
  ok "Security group tags cleaned up (only ${NODE_SG} retains the cluster tag)"
else
  warn "Could not determine infrastructure ID — skipping SG tag cleanup"
fi

# ─── Wait for ClusterVersion to be Available ─────────────────────────────
info "Waiting for ClusterVersion to become Available (up to 10 minutes)..."
CV_READY=false
for i in $(seq 1 60); do
  CV_STATUS=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  if [[ "$CV_STATUS" == "True" ]]; then
    CV_READY=true
    break
  fi
  echo -n "."
  sleep 10
done
echo ""

if [[ "$CV_READY" == "true" ]]; then
  ok "ClusterVersion is Available"
else
  warn "ClusterVersion not yet Available — operators may still be reconciling"
  warn "This may delay GPU operator initialization. Check: oc get co"
fi

# ─── Post-install ──────────────────────────────────────────────────────────
echo ""
ok "Cluster installation complete!"
echo ""
info "KUBECONFIG: ${KUBECONFIG}"
info "Run: export KUBECONFIG=${KUBECONFIG}"
echo ""

info "Cluster info:"
oc whoami 2>/dev/null && ok "Authenticated successfully" || warn "Could not authenticate — check KUBECONFIG"
oc get nodes -o wide 2>/dev/null || true

echo ""
info "Next step: ./02-label-nodes.sh"

