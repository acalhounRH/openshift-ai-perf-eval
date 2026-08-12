#!/usr/bin/env bash
# ============================================================================
# 03-install-operators.sh — Install all required operators and taint GPU node
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}"

echo ""
echo "============================================"
echo "  Installing Operators"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"
ok "Connected to cluster as $(oc whoami)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. NODE FEATURE DISCOVERY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${USE_SIMULATOR:-false}" == "true" ]]; then
  info "Simulator mode — skipping NFD and GPU Operator (no GPU required)"
else

info "Installing Node Feature Discovery (NFD) Operator..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: ${NFD_CHANNEL}
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for NFD operator deployment..."
sleep 30
oc wait --for=condition=Available deployment -l operators.coreos.com/nfd.openshift-nfd \
  -n openshift-nfd --timeout=300s 2>/dev/null || \
  warn "NFD operator deployment not yet ready — continuing (it may need more time)"

info "Waiting for NodeFeatureDiscovery CRD..."
for i in $(seq 1 30); do
  if oc get crd nodefeaturediscoveries.nfd.openshift.io >/dev/null 2>&1; then
    ok "NodeFeatureDiscovery CRD available"
    break
  fi
  echo -n "."
  sleep 10
done
echo ""

info "Creating NFD instance..."
oc apply -f - <<EOF
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery:latest
EOF

# The NFD operator may create the nfd-master Service with a mismatched selector
# (app.kubernetes.io/name vs app) or may not create it at all. Force correct state.
info "Ensuring nfd-master Service has correct selector..."
sleep 15
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nfd-master
  namespace: openshift-nfd
spec:
  selector:
    app: nfd-master
  ports:
  - port: 12000
    targetPort: 12000
    protocol: TCP
    name: grpc
  type: ClusterIP
EOF

# The nfd-master startup probe targets port 8080 but the binary only listens on
# gRPC 12000, causing infinite CrashLoopBackOff. Patch probes to use TCP/12000.
info "Fixing nfd-master health probes..."
oc patch deployment nfd-master -n openshift-nfd --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe","value":{"tcpSocket":{"port":12000},"failureThreshold":30,"periodSeconds":10}},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe","value":{"tcpSocket":{"port":12000},"periodSeconds":10}},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe","value":{"tcpSocket":{"port":12000},"periodSeconds":10}}
]' 2>/dev/null || warn "Could not patch nfd-master probes"

info "Waiting for nfd-master to become Ready..."
sleep 30
oc wait --for=condition=Available deployment/nfd-master \
  -n openshift-nfd --timeout=120s 2>/dev/null || \
  warn "nfd-master not yet ready — workers may not connect"

# Wait for NFD to label the GPU node with the NVIDIA PCI vendor ID (0x10de)
info "Waiting for NFD to label GPU node (feature.node.kubernetes.io/pci-10de.present)..."
NFD_LABELED=false
for i in $(seq 1 24); do
  GPU_LABELED=$(oc get nodes -l "feature.node.kubernetes.io/pci-10de.present=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$GPU_LABELED" -ge 1 ]]; then
    ok "NFD labeled GPU node with pci-10de.present=true"
    NFD_LABELED=true
    break
  fi
  echo -n "."
  sleep 10
done
echo ""

# Fallback: if NFD failed to label, apply the required labels manually
# so the GPU operator can proceed with driver installation.
if [[ "$NFD_LABELED" == "false" ]]; then
  warn "NFD did not label the GPU node in time. Applying labels manually..."
  GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/inference-worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  if [[ -n "$GPU_NODE" ]]; then
    KERNEL_VERSION=$(oc get node "$GPU_NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null)
    OS_IMAGE=$(oc get node "$GPU_NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)
    # Extract OSTREE_VERSION from OS image string, e.g. "Red Hat Enterprise Linux CoreOS 9.6.20260217-1 (Plow)"
    OSTREE_VERSION=$(echo "$OS_IMAGE" | grep -oP '\d+\.\d+\.\d{8,}-\d+' || echo "")

    oc label node "$GPU_NODE" \
      "feature.node.kubernetes.io/pci-10de.present=true" \
      "nvidia.com/gpu.present=true" \
      "feature.node.kubernetes.io/kernel-version.full=${KERNEL_VERSION}" \
      --overwrite
    if [[ -n "$OSTREE_VERSION" ]]; then
      VERSION_ID=$(echo "$OSTREE_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
      oc label node "$GPU_NODE" \
        "feature.node.kubernetes.io/system-os_release.OSTREE_VERSION=${OSTREE_VERSION}" \
        "feature.node.kubernetes.io/system-os_release.ID=rhcos" \
        "feature.node.kubernetes.io/system-os_release.VERSION_ID=${VERSION_ID}" \
        --overwrite
    fi
    ok "Manual labels applied to ${GPU_NODE}"
  else
    warn "No inference-worker node found to label"
  fi
fi

# The GPU Operator needs OSTREE_VERSION and VERSION_ID labels for DTK driver
# compilation. NFD may not set these even when running, so always ensure they exist.
GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/inference-worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
if [[ -n "$GPU_NODE" ]]; then
  EXISTING_OSTREE=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/system-os_release\.OSTREE_VERSION}' 2>/dev/null)
  EXISTING_VERSION_ID=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/system-os_release\.VERSION_ID}' 2>/dev/null)
  if [[ -z "$EXISTING_OSTREE" || -z "$EXISTING_VERSION_ID" ]]; then
    OS_IMAGE=$(oc get node "$GPU_NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)
    OSTREE_VERSION=$(echo "$OS_IMAGE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]{8,}-[0-9]+' || echo "")
    if [[ -n "$OSTREE_VERSION" ]]; then
      VERSION_ID=$(echo "$OSTREE_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
      info "Ensuring OSTREE_VERSION=${OSTREE_VERSION} and VERSION_ID=${VERSION_ID} on ${GPU_NODE}"
      oc label node "$GPU_NODE" \
        "feature.node.kubernetes.io/system-os_release.OSTREE_VERSION=${OSTREE_VERSION}" \
        "feature.node.kubernetes.io/system-os_release.ID=rhcos" \
        "feature.node.kubernetes.io/system-os_release.VERSION_ID=${VERSION_ID}" \
        --overwrite
    fi
  fi
fi

ok "NFD Operator installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. NVIDIA GPU OPERATOR
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing NVIDIA GPU Operator..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
    - nvidia-gpu-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${GPU_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for GPU operator deployment (this can take a few minutes)..."
sleep 45
oc wait --for=condition=Available deployment -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator \
  -n nvidia-gpu-operator --timeout=300s 2>/dev/null || \
  warn "GPU operator deployment not yet ready — continuing"

# The GPU Operator requires ClusterVersion to report Available=True before it
# will initialize the ClusterPolicy controller. Without this, the controller
# loops with "failed to find Completed Cluster Version".
info "Waiting for ClusterVersion to be Available (GPU operator requires this)..."
for i in $(seq 1 60); do
  CV_STATUS=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  if [[ "$CV_STATUS" == "True" ]]; then
    ok "ClusterVersion is Available"
    break
  fi
  if [[ $i -eq 60 ]]; then
    warn "ClusterVersion still not Available after 10 minutes."
    warn "GPU operator may fail to initialize. Check: oc get co"
  fi
  echo -n "."
  sleep 10
done
echo ""

info "Creating GPU ClusterPolicy..."
oc apply -f - <<EOF
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  daemonsets: {}
  driver:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: false
  nodeStatusExporter:
    enabled: true
  toolkit:
    enabled: true
EOF

ok "GPU Operator installed"

# Wait for GPU operator to deploy DaemonSets and register nvidia.com/gpu resources.
# The driver DaemonSet compiles a kernel module, which takes several minutes.
info "Waiting for GPU driver + device plugin on GPU node (up to 10 minutes)..."
GPU_READY=false
for i in $(seq 1 60); do
  GPU_NODE=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$GPU_NODE" ]]; then
    GPU_COUNT=$(oc get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [[ "$GPU_COUNT" -ge 1 ]] 2>/dev/null; then
      GPU_READY=true
      break
    fi
  fi
  echo -n "."
  sleep 10
done
echo ""

if [[ "$GPU_READY" == "true" ]]; then
  ok "GPU resources registered: ${GPU_COUNT} GPU(s) on ${GPU_NODE}"
  info "GPU operator pods:"
  oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | awk '{printf "  %-55s %s\n", $1, $3}'
else
  warn "GPU resources not yet allocatable after 10 minutes."
  warn "Check operator status: oc get pods -n nvidia-gpu-operator"
  warn "Check driver logs:     oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset"
fi

# The GPU operator does NOT create a ServiceMonitor for the DCGM exporter by
# default, so Prometheus never scrapes GPU metrics. Create one explicitly.
info "Creating ServiceMonitor for DCGM exporter..."
oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nvidia-dcgm-exporter
  namespace: nvidia-gpu-operator
  labels:
    app: nvidia-dcgm-exporter
spec:
  endpoints:
  - path: /metrics
    port: gpu-metrics
    interval: 15s
  namespaceSelector:
    matchNames:
    - nvidia-gpu-operator
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
EOF
ok "DCGM exporter ServiceMonitor created"

fi  # end USE_SIMULATOR check (NFD + GPU Operator)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. OPENSHIFT SERVERLESS (KNATIVE) — required for autoscaling evaluation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing OpenShift Serverless Operator..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-serverless
  namespace: openshift-serverless
spec: {}
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: ${SERVERLESS_CHANNEL}
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for Serverless operator..."
sleep 30
ok "Serverless Operator subscription created"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. OPENSHIFT SERVICE MESH 3 (ISTIO) — required by KServe Serverless mode
#    NOTE: Service Mesh v2 (servicemeshoperator) conflicts with the ingress
#    controller's Gateway API on OCP 4.20, causing Degraded state that blocks
#    ClusterVersion from completing. Use v3 only.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing OpenShift Service Mesh 3 Operator..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: ${SERVICE_MESH_CHANNEL}
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for Service Mesh 3 operator..."
sleep 30
ok "Service Mesh 3 Operator subscription created"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. CERT-MANAGER OPERATOR — required by RHOAI 3.x (KServe, Kueue)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing cert-manager Operator for Red Hat OpenShift..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: ${CERT_MANAGER_CHANNEL}
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for cert-manager operator..."
sleep 30
oc wait --for=condition=Available deployment/cert-manager \
  -n cert-manager --timeout=300s 2>/dev/null || \
  warn "cert-manager not yet ready — it may need more time"

ok "cert-manager Operator installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. RED HAT OPENSHIFT AI OPERATOR (RHOAI 3.x)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Installing Red Hat OpenShift AI Operator..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: ${OPENSHIFT_AI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

info "Waiting for RHOAI operator to install (this can take several minutes)..."
sleep 90

info "Waiting for DataScienceCluster CRD to become available..."
DSC_READY=false
for i in $(seq 1 30); do
  if oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; then
    ok "DataScienceCluster CRD is available"
    DSC_READY=true
    break
  fi
  echo -n "."
  sleep 10
done
echo ""

if [[ "$DSC_READY" == "true" ]]; then
  info "Creating DataScienceCluster with OGX (Llama Stack), KServe, and dashboard..."
  oc apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    kserve:
      managementState: Managed
      serving:
        managementState: Managed
    llamastackoperator:
      managementState: Removed
    ogx:
      managementState: Managed
    workbenches:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    ray:
      managementState: Removed
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    datasciencepipelines:
      managementState: Removed
    codeflare:
      managementState: Removed
    trustyai:
      managementState: Removed
    modelregistry:
      managementState: Removed
EOF

  ok "DataScienceCluster created — RHOAI components deploying (OGX is operator-managed)"
  info "Monitor DSC: oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'"
  info "Monitor OGX: oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=ogx-k8s-operator"
else
  warn "DataScienceCluster CRD did not appear. RHOAI operator may have failed to install."
  warn "Check: oc get subscription rhods-operator -n redhat-ods-operator -o yaml"
  warn "Continuing with remaining operators..."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. ENABLE USER WORKLOAD MONITORING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Enabling user workload monitoring (allows Prometheus to scrape app metrics)..."

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

info "Waiting for user workload monitoring pods..."
sleep 15
oc wait --for=condition=Available deployment/prometheus-operator \
  -n openshift-user-workload-monitoring --timeout=180s 2>/dev/null || \
  warn "User workload monitoring not yet ready — it may need more time"

ok "User workload monitoring enabled"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. OPENTELEMETRY OPERATOR
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${OTEL_ENABLED}" == "true" ]]; then
  info "Installing Red Hat OpenTelemetry Operator..."

  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-operators
spec:
  channel: ${OTEL_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  info "Waiting for OpenTelemetry operator..."
  sleep 30

  # The OTel operator sometimes creates an install plan with Manual approval
  # even when the subscription specifies Automatic. Auto-approve if needed.
  for i in $(seq 1 6); do
    PENDING_IP=$(oc get installplan -n openshift-operators -o json 2>/dev/null | \
      jq -r '.items[] | select(.spec.approved == false) | select(.spec.clusterServiceVersionNames[] | test("opentelemetry")) | .metadata.name' 2>/dev/null | head -1)
    if [[ -n "$PENDING_IP" ]]; then
      warn "OTel install plan ${PENDING_IP} requires approval — auto-approving"
      oc patch installplan "${PENDING_IP}" -n openshift-operators \
        --type=merge -p '{"spec":{"approved":true}}' 2>/dev/null
      break
    fi
    sleep 10
  done

  info "Waiting for OpenTelemetryCollector CRD..."
  for i in $(seq 1 30); do
    if oc get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
      ok "OpenTelemetryCollector CRD available"
      break
    fi
    echo -n "."
    sleep 10
  done
  echo ""

  oc wait --for=condition=Available deployment -l app.kubernetes.io/name=opentelemetry-operator \
    -n openshift-operators --timeout=300s 2>/dev/null || \
    warn "OpenTelemetry operator not yet ready — continuing"

  ok "OpenTelemetry Operator installed"
else
  info "OpenTelemetry disabled (OTEL_ENABLED=${OTEL_ENABLED}) — skipping"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SUMMARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "============================================"
echo "  Operator Installation Summary"
echo "============================================"
info "Installed operators:"
oc get subscriptions -A --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $2, $1}'
echo ""
info "Cluster operators status:"
oc get co --no-headers 2>/dev/null | awk '{printf "  %-45s Available=%-6s Degraded=%s\n", $1, $3, $5}' | head -20
echo ""
ok "Operator installation complete."
warn "Some operators may still be reconciling. Wait 5-10 minutes before proceeding."
echo ""
info "Next step: ./04-deploy-stack.sh"

