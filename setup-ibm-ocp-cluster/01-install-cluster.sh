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
# Single worker pool (app-worker). Additional MachineSets are created by
# 02-label-nodes.sh after installation, matching the AWS workflow.
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
  - name: worker
    replicas: 1
    platform:
      ibmcloud:
        type: ${APP_WORKER_INSTANCE_TYPE}
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

# ─── Install the cluster ────────────────────────────────────────────────
echo ""
info "Starting cluster installation (~35-50 minutes)..."
info "Logs: ${INSTALLER_DIR}/.openshift_install.log"
info ""
info "IBM Cloud IPI will automatically create:"
info "  - VPC and subnets"
info "  - Security groups"
info "  - Load balancers"
info "  - DNS records in CIS"
info "  - 3 master nodes + 1 worker node"
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

# ─── Ensure cloud credential secrets exist in operator namespaces ─────────
# IBM Cloud IPI sometimes fails to propagate the API key into the namespaces
# that operators need. Without these secrets the cloud-controller-manager,
# machine-api, ingress, CSI, and image-registry operators stall indefinitely.
info "Ensuring cloud-provider credential secrets exist in operator namespaces..."

IBM_API_KEY=$(oc get secret ibmcloud-credentials -n kube-system \
  -o jsonpath='{.data.ibmcloud_api_key}' 2>/dev/null | base64 -d 2>/dev/null)

if [[ -z "${IBM_API_KEY:-}" ]]; then
  warn "Could not read ibmcloud-credentials from kube-system — using IC_API_KEY from env"
  IBM_API_KEY="${IC_API_KEY}"
fi

ensure_credential_secret() {
  local ns="$1" secret_name="$2" key_field="$3"
  if oc get secret "$secret_name" -n "$ns" >/dev/null 2>&1; then
    ok "Secret ${secret_name} already exists in ${ns}"
    return
  fi
  oc create namespace "$ns" --dry-run=client -o yaml 2>/dev/null | oc apply -f - >/dev/null 2>&1
  oc create secret generic "$secret_name" \
    --from-literal="${key_field}=${IBM_API_KEY}" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
  ok "Created ${secret_name} in ${ns}"
}

ensure_credential_secret "openshift-cloud-controller-manager" "ibm-cloud-credentials"     "ibmcloud_api_key"
ensure_credential_secret "openshift-machine-api"              "ibmcloud-credentials"       "ibmcloud_api_key"
ensure_credential_secret "openshift-ingress-operator"         "cloud-credentials"          "ibmcloud_api_key"
ensure_credential_secret "openshift-cluster-csi-drivers"      "ibm-cloud-credentials"      "ibmcloud_api_key"
ensure_credential_secret "openshift-image-registry"           "installer-cloud-credentials" "ibmcloud_api_key"

# ─── Fix ingress LB security group (allow inbound 80/443 from internet) ──
# IBM Cloud creates the ingress VPC Load Balancer with a security group that
# only allows traffic from its own members. Without public inbound 80/443,
# *.apps routes (OAuth, console, etc.) are unreachable and several operators
# report Degraded.
info "Waiting for ingress LoadBalancer to appear (up to 5 minutes)..."

INGRESS_LB_HOST=""
for i in $(seq 1 30); do
  INGRESS_LB_HOST=$(oc get svc -n openshift-ingress router-default \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$INGRESS_LB_HOST" ]] && break
  echo -n "."
  sleep 10
done
echo ""

if [[ -n "$INGRESS_LB_HOST" ]]; then
  ok "Ingress LB hostname: ${INGRESS_LB_HOST}"

  LB_PREFIX=$(echo "$INGRESS_LB_HOST" | cut -d'-' -f1)
  INGRESS_LB_ID=$(ibmcloud is load-balancers --output json 2>/dev/null \
    | jq -r ".[] | select(.hostname == \"${INGRESS_LB_HOST}\") | .id" 2>/dev/null)

  if [[ -z "$INGRESS_LB_ID" ]]; then
    INGRESS_LB_ID=$(ibmcloud is load-balancers --output json 2>/dev/null \
      | jq -r ".[] | select(.id | startswith(\"${LB_PREFIX}\")) | .id" | head -1 2>/dev/null)
  fi

  if [[ -n "$INGRESS_LB_ID" ]]; then
    SG_ID=$(ibmcloud is load-balancer "$INGRESS_LB_ID" --output json 2>/dev/null \
      | jq -r '.security_groups[0].id' 2>/dev/null)

    if [[ -n "$SG_ID" && "$SG_ID" != "null" ]]; then
      info "Ingress LB security group: ${SG_ID}"

      HAS_443=$(ibmcloud is security-group-rules "$SG_ID" --output json 2>/dev/null \
        | jq '[.[] | select(.direction=="inbound" and .protocol=="tcp"
              and .port_min==443 and .remote.cidr_block=="0.0.0.0/0")] | length' 2>/dev/null)
      HAS_80=$(ibmcloud is security-group-rules "$SG_ID" --output json 2>/dev/null \
        | jq '[.[] | select(.direction=="inbound" and .protocol=="tcp"
              and .port_min==80 and .remote.cidr_block=="0.0.0.0/0")] | length' 2>/dev/null)

      if [[ "${HAS_443:-0}" -eq 0 ]]; then
        ibmcloud is security-group-rule-add "$SG_ID" inbound tcp \
          --port-min 443 --port-max 443 --remote 0.0.0.0/0 >/dev/null 2>&1
        ok "Added inbound TCP 443 from 0.0.0.0/0"
      else
        ok "Inbound TCP 443 rule already exists"
      fi

      if [[ "${HAS_80:-0}" -eq 0 ]]; then
        ibmcloud is security-group-rule-add "$SG_ID" inbound tcp \
          --port-min 80 --port-max 80 --remote 0.0.0.0/0 >/dev/null 2>&1
        ok "Added inbound TCP 80 from 0.0.0.0/0"
      else
        ok "Inbound TCP 80 rule already exists"
      fi
    else
      warn "Could not determine ingress LB security group — check manually"
    fi
  else
    warn "Could not find ingress LB in ibmcloud — check manually"
  fi
else
  warn "Ingress LB not ready after 5 minutes — security group fix skipped"
  warn "You may need to manually add inbound TCP 80/443 from 0.0.0.0/0 to the ingress LB security group"
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

# ─── Post-install ────────────────────────────────────────────────────────
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
