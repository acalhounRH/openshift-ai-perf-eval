#!/usr/bin/env bash
# ============================================================================
# 01-install-cluster.sh — Generate install-config.yaml and install self-managed
#                          OCP cluster on IBM Cloud VPC
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Installing Self-Managed OCP Cluster"
echo "  Name:   ${CLUSTER_NAME}"
echo "  Domain: ${BASE_DOMAIN}"
echo "  Region: ${IBMCLOUD_REGION} / ${IBMCLOUD_ZONE}"
echo "============================================"
echo ""

# ─── Verify IC_API_KEY ────────────────────────────────────────────────────
[[ -n "${IC_API_KEY}" ]] || bail "IC_API_KEY is not set. Run: export IC_API_KEY=<your-key>"

# ─── Read secrets ─────────────────────────────────────────────────────────
PULL_SECRET=$(cat "${PULL_SECRET_FILE}")
SSH_KEY=$(cat "${SSH_PUBLIC_KEY_FILE}")

# ─── Create installer directory ──────────────────────────────────────────
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

# ─── Generate install-config.yaml ────────────────────────────────────────
info "Generating install-config.yaml..."

cat > "${INSTALLER_DIR}/install-config.yaml" <<YAML
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  ibmcloud:
    region: ${IBMCLOUD_REGION}
controlPlane:
  name: master
  replicas: 3
  platform:
    ibmcloud:
      type: ${MASTER_INSTANCE_TYPE}
      zones:
        - ${IBMCLOUD_ZONE}
compute:
  - name: app-worker
    replicas: 1
    platform:
      ibmcloud:
        type: ${APP_WORKER_INSTANCE_TYPE}
        zones:
          - ${IBMCLOUD_ZONE}
  - name: inference-worker
    replicas: 1
    platform:
      ibmcloud:
        type: ${INFERENCE_WORKER_INSTANCE_TYPE}
        zones:
          - ${IBMCLOUD_ZONE}
  - name: loadgen-worker
    replicas: 1
    platform:
      ibmcloud:
        type: ${LOADGEN_WORKER_INSTANCE_TYPE}
        zones:
          - ${IBMCLOUD_ZONE}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
YAML

ok "install-config.yaml generated"

# ─── Save a backup (openshift-install consumes the file) ─────────────────
cp "${INSTALLER_DIR}/install-config.yaml" "${INSTALLER_DIR}/install-config.yaml.bak"
info "Backup saved to install-config.yaml.bak"

# ─── Create manifests ────────────────────────────────────────────────────
info "Creating manifests..."
openshift-install create manifests --dir="${INSTALLER_DIR}" --log-level=info

# ─── Set masters to NOT schedulable ──────────────────────────────────────
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

# ─── Install the cluster ─────────────────────────────────────────────────
echo ""
info "Starting cluster installation (~35-50 minutes)..."
info "Logs: ${INSTALLER_DIR}/.openshift_install.log"
info ""
info "IBM Cloud IPI will automatically create:"
info "  - VPC and subnets"
info "  - Security groups"
info "  - Load balancers"
info "  - DNS records in CIS"
info "  - 3 master nodes + 3 worker nodes"
echo ""

openshift-install create cluster --dir="${INSTALLER_DIR}" --log-level=info

# ─── Post-install ─────────────────────────────────────────────────────────
echo ""
ok "Cluster installation complete!"
echo ""
info "KUBECONFIG: ${KUBECONFIG}"
info "Run: export KUBECONFIG=${KUBECONFIG}"
echo ""

export KUBECONFIG="${INSTALLER_DIR}/auth/kubeconfig"
info "Cluster info:"
oc whoami 2>/dev/null && ok "Authenticated successfully" || warn "Could not authenticate — check KUBECONFIG"
oc get nodes -o wide 2>/dev/null || true

echo ""
info "Next step: ./02-label-nodes.sh"

