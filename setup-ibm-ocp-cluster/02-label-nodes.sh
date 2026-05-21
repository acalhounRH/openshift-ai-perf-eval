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
# 1. LABEL THE INITIAL WORKER AS APP-WORKER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Labeling initial worker node as app-worker..."
APP_NODE=$(oc get nodes \
  -l "node-role.kubernetes.io/worker,!node-role.kubernetes.io/master" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

if [[ -n "$APP_NODE" ]]; then
  oc label node "${APP_NODE}" node-role.kubernetes.io/app-worker="" --overwrite
  ok "App worker labeled: ${APP_NODE}"
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
# 2. CREATE INFERENCE WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INFERENCE_MS_NAME="${INFRA_ID}-inference-worker-${IBMCLOUD_ZONE}"
create_machineset "${INFERENCE_MS_NAME}" "${INFERENCE_WORKER_INSTANCE_TYPE}" "inference-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. CREATE TOOLS WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOOLS_MS_NAME="${INFRA_ID}-tools-worker-${IBMCLOUD_ZONE}"
create_machineset "${TOOLS_MS_NAME}" "${TOOLS_WORKER_INSTANCE_TYPE}" "tools-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. CREATE RAG WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RAG_MS_NAME="${INFRA_ID}-rag-worker-${IBMCLOUD_ZONE}"
create_machineset "${RAG_MS_NAME}" "${RAG_WORKER_INSTANCE_TYPE}" "rag-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. CREATE LOADGEN WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOADGEN_MS_NAME="${INFRA_ID}-loadgen-worker-${IBMCLOUD_ZONE}"
create_machineset "${LOADGEN_MS_NAME}" "${LOADGEN_WORKER_INSTANCE_TYPE}" "loadgen-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. WAIT FOR NEW NODES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Waiting for new worker nodes to provision (5-10 minutes)..."
echo ""

for i in $(seq 1 60); do
  INFERENCE_READY=$(oc get nodes -l node-role.kubernetes.io/inference-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  TOOLS_READY=$(oc get nodes -l node-role.kubernetes.io/tools-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  RAG_READY=$(oc get nodes -l node-role.kubernetes.io/rag-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  LOADGEN_READY=$(oc get nodes -l node-role.kubernetes.io/loadgen-worker --no-headers 2>/dev/null | grep -c " Ready" || true)

  if [[ "$INFERENCE_READY" -ge 1 && "$TOOLS_READY" -ge 1 && "$RAG_READY" -ge 1 && "$LOADGEN_READY" -ge 1 ]]; then
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
oc get nodes -L node-role.kubernetes.io/app-worker,node-role.kubernetes.io/inference-worker,node-role.kubernetes.io/tools-worker,node-role.kubernetes.io/rag-worker,node-role.kubernetes.io/loadgen-worker
echo ""

ok "Node setup complete."
echo ""
info "Next step: ./03-install-operators.sh"
