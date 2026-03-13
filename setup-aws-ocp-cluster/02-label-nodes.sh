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

# ─── Extract providerSpec from the working MachineSet ──────────────────────
TEMPLATE_JSON=$(oc get machineset/${DEFAULT_MS} -n openshift-machine-api -o json)
AMI_ID=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.ami.id')
SECURITY_GROUPS=$(echo "$TEMPLATE_JSON" | jq '.spec.template.spec.providerSpec.value.securityGroups')
SUBNET=$(echo "$TEMPLATE_JSON" | jq '.spec.template.spec.providerSpec.value.subnet')
IAM_PROFILE=$(echo "$TEMPLATE_JSON" | jq -r '.spec.template.spec.providerSpec.value.iamInstanceProfile.id')

info "  AMI: ${AMI_ID}"
info "  IAM Profile: ${IAM_PROFILE}"

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
# Helper: create a MachineSet by cloning the working template
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_machineset() {
  local ms_name="$1"
  local instance_type="$2"
  local volume_size="$3"
  local role_label="$4"

  info "Creating MachineSet: ${ms_name} (${instance_type})..."

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
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          ami:
            id: ${AMI_ID}
          instanceType: ${instance_type}
          placement:
            availabilityZone: ${AWS_ZONE}
            region: ${AWS_REGION}
          blockDevices:
          - ebs:
              encrypted: true
              volumeSize: ${volume_size}
              volumeType: ${ROOT_VOLUME_TYPE}
          iamInstanceProfile:
            id: ${IAM_PROFILE}
          securityGroups: ${SECURITY_GROUPS}
          subnet: ${SUBNET}
          tags:
          - name: kubernetes.io/cluster/${INFRA_ID}
            value: owned
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: aws-cloud-credentials
EOF
  ok "MachineSet ${ms_name} created"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CREATE INFERENCE WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INFERENCE_MS_NAME="${INFRA_ID}-inference-worker-${AWS_ZONE}"
create_machineset "${INFERENCE_MS_NAME}" "${INFERENCE_WORKER_INSTANCE_TYPE}" "${INFERENCE_WORKER_ROOT_VOLUME_SIZE}" "inference-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. CREATE LOADGEN WORKER MACHINESET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOADGEN_MS_NAME="${INFRA_ID}-loadgen-worker-${AWS_ZONE}"
create_machineset "${LOADGEN_MS_NAME}" "${LOADGEN_WORKER_INSTANCE_TYPE}" "${LOADGEN_WORKER_ROOT_VOLUME_SIZE}" "loadgen-worker"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. WAIT FOR NEW NODES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Waiting for new worker nodes to provision (5-10 minutes)..."
echo ""

for i in $(seq 1 60); do
  INFERENCE_READY=$(oc get nodes -l node-role.kubernetes.io/inference-worker --no-headers 2>/dev/null | grep -c " Ready" || true)
  LOADGEN_READY=$(oc get nodes -l node-role.kubernetes.io/loadgen-worker --no-headers 2>/dev/null | grep -c " Ready" || true)

  if [[ "$INFERENCE_READY" -ge 1 && "$LOADGEN_READY" -ge 1 ]]; then
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
oc get nodes -L node-role.kubernetes.io/app-worker,node-role.kubernetes.io/inference-worker,node-role.kubernetes.io/loadgen-worker
echo ""

ok "Node setup complete."
echo ""
info "Next step: ./03-install-operators.sh"
