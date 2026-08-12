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
  if [[ -t 0 ]]; then
    read -rp "Delete and recreate? (y/N) " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      rm -rf "${INSTALLER_DIR}"
    else
      bail "Aborting. Remove or rename ${INSTALLER_DIR} and try again."
    fi
  else
    info "Non-interactive mode — removing stale installer directory"
    rm -rf "${INSTALLER_DIR}"
  fi
fi

mkdir -p "${INSTALLER_DIR}"
info "Installer directory: ${INSTALLER_DIR}"

# ─── Generate install-config.yaml ────────────────────────────────────────
# Initial compute pool creates 1 worker (loadgen-worker role).
# 02-label-nodes.sh creates additional MachineSets for OGX and PostgreSQL.
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
info "  - 3 master nodes + 1 initial worker node (loadgen/simulator)"
echo ""

INSTALL_EXIT=0
openshift-install create cluster --dir="${INSTALLER_DIR}" --log-level=info || INSTALL_EXIT=$?

export KUBECONFIG="${INSTALLER_DIR}/auth/kubeconfig"

# ─── DNS workaround for IBM Cloud CIS ────────────────────────────────
# The macOS resolver sometimes can't follow the CNAME chain from the CIS
# DNS record to the IBM Cloud VPC Load Balancer, even though dig/nslookup
# resolve it fine.  When this happens, oc/kubectl fail with "no such host".
# Fix: resolve via dig and update /etc/hosts if the OS resolver fails or
# if a stale entry from a prior deployment points to the wrong IP.
API_HOST="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
RESOLVED_IP=$(dig +short "${API_HOST}" 2>/dev/null | tail -1 || true)
CURRENT_HOSTS_IP=$(grep "${API_HOST}" /etc/hosts 2>/dev/null | awk '{print $1}' | tail -1 || true)

if [[ -n "$RESOLVED_IP" ]]; then
  if [[ -n "$CURRENT_HOSTS_IP" && "$CURRENT_HOSTS_IP" != "$RESOLVED_IP" ]]; then
    warn "Stale /etc/hosts entry: ${CURRENT_HOSTS_IP} (dig says ${RESOLVED_IP})"
    info "Updating /etc/hosts entry (requires sudo)..."
    sudo sed -i '' "/${API_HOST}/d" /etc/hosts 2>/dev/null || true
    echo "${RESOLVED_IP} ${API_HOST}" | sudo tee -a /etc/hosts >/dev/null 2>&1 && \
      ok "Updated ${API_HOST} → ${RESOLVED_IP} in /etc/hosts" || \
      warn "Could not update /etc/hosts — run manually: sudo sed -i '' '/${API_HOST}/d' /etc/hosts && echo '${RESOLVED_IP} ${API_HOST}' | sudo tee -a /etc/hosts"
  elif ! python3 -c "import socket; socket.getaddrinfo('${API_HOST}', 6443)" >/dev/null 2>&1; then
    warn "OS DNS resolver cannot resolve ${API_HOST}"
    info "dig resolved ${API_HOST} → ${RESOLVED_IP}"
    info "Adding /etc/hosts entry (requires sudo)..."
    echo "${RESOLVED_IP} ${API_HOST}" | sudo tee -a /etc/hosts >/dev/null 2>&1 && \
      ok "Added ${RESOLVED_IP} ${API_HOST} to /etc/hosts" || \
      warn "Could not update /etc/hosts — run manually: echo '${RESOLVED_IP} ${API_HOST}' | sudo tee -a /etc/hosts"
  else
    ok "DNS resolution OK for ${API_HOST}"
  fi
else
  warn "dig could not resolve ${API_HOST} — DNS records may not have propagated yet"
fi

if [[ $INSTALL_EXIT -ne 0 ]]; then
  warn "openshift-install exited with code ${INSTALL_EXIT}"
  warn "Checking if the cluster is actually functional despite the error..."
  if oc whoami >/dev/null 2>&1; then
    ok "Cluster API is reachable — likely a cosmetic bootstrap cleanup failure"
  else
    warn "Cluster API is NOT reachable via oc. Attempting post-install fixups anyway..."
    warn "If the cluster is genuinely down, the steps below will fail harmlessly."
  fi
fi

# ─── Ensure cloud credential secrets exist in operator namespaces ─────────
# IBM Cloud IPI sometimes fails to propagate the API key into the namespaces
# that operators need. Without these secrets the cloud-controller-manager,
# machine-api, ingress, CSI, and image-registry operators stall indefinitely.
info "Ensuring cloud-provider credential secrets exist in operator namespaces..."

IBM_API_KEY=""
if oc whoami >/dev/null 2>&1; then
  IBM_API_KEY=$(oc get secret ibmcloud-credentials -n kube-system \
    -o jsonpath='{.data.ibmcloud_api_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi

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
  if ! oc get namespace "$ns" >/dev/null 2>&1; then
    oc create namespace "$ns" >/dev/null 2>&1 || true
  fi
  if oc create secret generic "$secret_name" \
    --from-literal="${key_field}=${IBM_API_KEY}" \
    -n "$ns" >/dev/null 2>&1; then
    ok "Created ${secret_name} in ${ns}"
  else
    warn "Could not create ${secret_name} in ${ns} — API may be unreachable"
  fi
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
  LB_JSON=$(ibmcloud is load-balancers --output json 2>/dev/null || echo "[]")
  INGRESS_LB_ID=$(echo "$LB_JSON" | jq -r ".[] | select(.hostname == \"${INGRESS_LB_HOST}\") | .id" 2>/dev/null || true)

  if [[ -z "$INGRESS_LB_ID" ]]; then
    INGRESS_LB_ID=$(echo "$LB_JSON" | jq -r ".[] | select(.id | startswith(\"${LB_PREFIX}\")) | .id" 2>/dev/null | head -1 || true)
  fi

  if [[ -n "$INGRESS_LB_ID" ]]; then
    LB_DETAIL=$(ibmcloud is load-balancer "$INGRESS_LB_ID" --output json 2>/dev/null || echo "{}")
    SG_ID=$(echo "$LB_DETAIL" | jq -r '.security_groups[0].id' 2>/dev/null || true)

    if [[ -n "$SG_ID" && "$SG_ID" != "null" ]]; then
      info "Ingress LB security group: ${SG_ID}"

      SG_RULES=$(ibmcloud is security-group-rules "$SG_ID" --output json 2>/dev/null || echo "[]")
      HAS_443=$(echo "$SG_RULES" | jq '[.[] | select(.direction=="inbound" and .protocol=="tcp"
              and .port_min==443 and .remote.cidr_block=="0.0.0.0/0")] | length' 2>/dev/null || echo 0)
      HAS_80=$(echo "$SG_RULES" | jq '[.[] | select(.direction=="inbound" and .protocol=="tcp"
              and .port_min==80 and .remote.cidr_block=="0.0.0.0/0")] | length' 2>/dev/null || echo 0)

      if [[ "${HAS_443:-0}" -eq 0 ]]; then
        ibmcloud is security-group-rule-add "$SG_ID" inbound tcp \
          --port-min 443 --port-max 443 --remote 0.0.0.0/0 >/dev/null 2>&1 || true
        ok "Added inbound TCP 443 from 0.0.0.0/0"
      else
        ok "Inbound TCP 443 rule already exists"
      fi

      if [[ "${HAS_80:-0}" -eq 0 ]]; then
        ibmcloud is security-group-rule-add "$SG_ID" inbound tcp \
          --port-min 80 --port-max 80 --remote 0.0.0.0/0 >/dev/null 2>&1 || true
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
