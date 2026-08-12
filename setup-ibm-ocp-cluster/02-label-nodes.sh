#!/usr/bin/env bash
# ============================================================================
# 02-label-nodes.sh — Create MachineSets for inference/loadgen workers, label nodes
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "============================================"
echo "  Creating Worker MachineSets & Labeling Nodes"
echo "============================================"
echo ""

# ─── Verify connectivity ───────────────────────────────────────────────────
oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"
ok "Connected to cluster as $(oc whoami)"

# ─── Show current nodes ────────────────────────────────────────────────────
info "Current node list:"
oc get nodes -o wide
echo ""

# ─── Get the infrastructure ID (used in MachineSet naming) ─────────────────
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
info "Infrastructure ID: ${INFRA_ID}"

# ─── Get the default worker MachineSet name ────────────────────────────────
DEFAULT_MS=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}')
info "Using ${DEFAULT_MS} as template for new MachineSets"

# ─── Extract providerSpec fields from the working MachineSet ───────────────
TEMPLATE_JSON=$(oc get machineset/${DEFAULT_MS} -n openshift-machine-api -o json)

IBM_IMAGE=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.image')
IBM_VPC=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.vpc')
IBM_RESOURCE_GROUP=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.resourceGroup')
IBM_REGION=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.region')
IBM_ZONE=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.zone')
IBM_SECURITY_GROUPS=$(echo "$TEMPLATE_JSON" | jq '.spec.template.spec.providerSpec.value.primaryNetworkInterface.securityGroups')
IBM_SUBNET=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.primaryNetworkInterface.subnet')

info "  Image:          ${IBM_IMAGE}"
info "  VPC:            ${IBM_VPC}"
info "  Resource Group: ${IBM_RESOURCE_GROUP}"
info "  Region/Zone:    ${IBM_REGION} / ${IBM_ZONE}"
info "  Subnet:         ${IBM_SUBNET}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. LABEL THE INITIAL WORKER AS LOADGEN-WORKER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Labeling initial worker node as loadgen-worker (simulator + GuideLLM)..."
LOADGEN_NODE=$(oc get nodes \
  -l "node-role.kubernetes.io/worker,!node-role.kubernetes.io/master" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

if [[ -n "$LOADGEN_NODE" ]]; then
  oc label node "${LOADGEN_NODE}" node-role.kubernetes.io/loadgen-worker="" --overwrite
  ok "Loadgen worker labeled: ${LOADGEN_NODE}"
else
  warn "No worker node found yet — label manually after node is ready"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper: create an IBM Cloud VPC MachineSet by cloning the working template
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_machineset() {
  local ms_name="$1"
  local instance_profile="$2"
  local role_label="$3"

  info "Creating MachineSet: ${ms_name} (${instance_profile})..."

  cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${ms_name}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
      machine.openshift.io/cluster-api-machineset: ${ms_name}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
        machine.openshift.io/cluster-api-machineset: ${ms_name}
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
    spec:
      metadata:
        labels:
          node-role.kubernetes.io/worker: ""
          node-role.kubernetes.io/${role_label}: ""
      providerSpec:
        value:
          apiVersion: ibmcloudproviderconfig.openshift.io/v1beta1
          kind: IBMCloudMachineProviderSpec
          image: ${IBM_IMAGE}
          profile: ${instance_profile}
          region: ${IBM_REGION}
          zone: ${IBM_ZONE}
          resourceGroup: ${IBM_RESOURCE_GROUP}
          vpc: ${IBM_VPC}
          primaryNetworkInterface:
            securityGroups: ${IBM_SECURITY_GROUPS}
            subnet: ${IBM_SUBNET}
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: ibmcloud-credentials
EOF
  ok "MachineSet ${ms_name} created"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CREATE OGX WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OGX_MS_NAME="${INFRA_ID}-ogx-worker-${IBMCLOUD_ZONE}"
create_machineset "${OGX_MS_NAME}" "${OGX_WORKER_INSTANCE_TYPE}" "ogx-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. CREATE POSTGRESQL WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
POSTGRES_MS_NAME="${INFRA_ID}-postgres-worker-${IBMCLOUD_ZONE}"
create_machineset "${POSTGRES_MS_NAME}" "${POSTGRES_WORKER_INSTANCE_TYPE}" "postgres-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. WAIT FOR NEW NODES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Waiting for new worker nodes to provision (5-10 minutes)..."
echo ""

for i in $(seq 1 60); do
  OGX_READY=$(oc get nodes -l node-role.kubernetes.io/ogx-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  POSTGRES_READY=$(oc get nodes -l node-role.kubernetes.io/postgres-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  LOADGEN_READY=$(oc get nodes -l node-role.kubernetes.io/loadgen-worker --no-headers 2>/dev/null | grep -c " Ready" || true)

  if [[ "$OGX_READY" -ge 1 && "$POSTGRES_READY" -ge 1 && "$LOADGEN_READY" -ge 1 ]]; then
    echo ""
    ok "All worker nodes are ready"
    break
  fi

  echo -n "."
  sleep 10
done

# ─── Verify ─────────────────────────────────────────────────────────────────
echo ""
info "Final node list:"
oc get nodes -o wide
echo ""

info "MachineSets:"
oc get machinesets -n openshift-machine-api
echo ""

info "Node roles:"
oc get nodes -L node-role.kubernetes.io/ogx-worker,node-role.kubernetes.io/postgres-worker,node-role.kubernetes.io/loadgen-worker
echo ""

ok "Node setup complete."
echo ""
info "Next step: ./03-install-operators.sh"
