#!/usr/bin/env bash
# ============================================================================
# 04-deploy-stack.sh — Deploy PostgreSQL, inference backend, and MCP servers
#
# NOTE: OGX is deployed by the RHOAI operator via the DataScienceCluster CR
# (ogx component, RHOAI 3.5 EA1+). This script creates an OGXServer CR.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}"

echo ""
echo "============================================"
echo "  Deploying AI Stack"
echo "  Namespace: ${PERF_NAMESPACE}"
echo "  Model:     ${MODEL_ID}"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"
ok "Connected to cluster as $(oc whoami)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. CREATE NAMESPACE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating namespace ${PERF_NAMESPACE}..."
oc create namespace "${PERF_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
ok "Namespace ${PERF_NAMESPACE} ready"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1b. ADDITIONAL PULL SECRET (for private registries like quay.io/rhoai)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ -n "${ADDITIONAL_PULL_SECRET_FILE:-}" && -f "${ADDITIONAL_PULL_SECRET_FILE}" ]]; then
  info "Configuring additional pull secret from ${ADDITIONAL_PULL_SECRET_FILE}..."
  oc create secret generic additional-pull-secret \
    --from-file=.dockerconfigjson="${ADDITIONAL_PULL_SECRET_FILE}" \
    --type=kubernetes.io/dockerconfigjson \
    -n "${PERF_NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -
  oc secrets link default additional-pull-secret --for=pull -n "${PERF_NAMESPACE}" 2>/dev/null || true
  ok "Additional pull secret configured in ${PERF_NAMESPACE}"
elif [[ -n "${ADDITIONAL_PULL_SECRET_FILE:-}" ]]; then
  warn "ADDITIONAL_PULL_SECRET_FILE is set but file not found: ${ADDITIONAL_PULL_SECRET_FILE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CREATE PERSISTENT VOLUME CLAIMS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating PVCs..."

oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: benchmark-results
  namespace: ${PERF_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${BENCHMARK_RESULTS_STORAGE_SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF

if [[ "${USE_SIMULATOR:-false}" != "true" ]]; then
  oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage
  namespace: ${PERF_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${MODEL_STORAGE_SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF
  ok "PVCs created (model-storage: ${MODEL_STORAGE_SIZE}, benchmark-results: ${BENCHMARK_RESULTS_STORAGE_SIZE})"
else
  ok "PVCs created (benchmark-results: ${BENCHMARK_RESULTS_STORAGE_SIZE}) — model-storage skipped (simulator mode)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. DEPLOY POSTGRESQL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Deploying PostgreSQL (sessions, config, cache)..."

# The standard postgres:16 image requires running as UID 999 (postgres user).
# OpenShift assigns random UIDs by default, which breaks PostgreSQL initialization.
info "Granting anyuid SCC to default service account for PostgreSQL..."
oc adm policy add-scc-to-user anyuid -z default -n "${PERF_NAMESPACE}" 2>/dev/null || true

# Create credentials secret
oc create secret generic postgresql-credentials \
  --from-literal=username="${POSTGRESQL_USER}" \
  --from-literal=password="${POSTGRESQL_PASSWORD}" \
  --from-literal=database="${POSTGRESQL_DB}" \
  --from-literal=connection-string="postgresql://${POSTGRESQL_USER}:${POSTGRESQL_PASSWORD}@postgresql:5432/${POSTGRESQL_DB}" \
  -n "${PERF_NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
  namespace: ${PERF_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${POSTGRESQL_STORAGE_SIZE}
  storageClassName: ${STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: ${PERF_NAMESPACE}
  labels:
    app: postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      nodeSelector:
        node-role.kubernetes.io/postgres-worker: ""
      containers:
      - name: postgres
        image: ${POSTGRESQL_IMAGE}
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: database
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "1"
            memory: "2Gi"
        volumeMounts:
        - name: pg-data
          mountPath: /var/lib/postgresql/data
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "\$(POSTGRES_USER)", "-d", "\$(POSTGRES_DB)"]
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "\$(POSTGRES_USER)", "-d", "\$(POSTGRES_DB)"]
          initialDelaySeconds: 30
          periodSeconds: 10
      - name: postgres-exporter
        image: quay.io/prometheuscommunity/postgres-exporter:v0.16.0
        ports:
        - containerPort: 9187
          name: metrics
          protocol: TCP
        env:
        - name: DATA_SOURCE_URI
          value: "localhost:5432/${POSTGRESQL_DB}?sslmode=disable"
        - name: DATA_SOURCE_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: username
        - name: DATA_SOURCE_PASS
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: password
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
        livenessProbe:
          httpGet:
            path: /metrics
            port: 9187
          initialDelaySeconds: 10
          periodSeconds: 30
      volumes:
      - name: pg-data
        persistentVolumeClaim:
          claimName: postgresql-data
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: ${PERF_NAMESPACE}
  labels:
    app: postgresql
spec:
  selector:
    app: postgresql
  ports:
  - port: 5432
    targetPort: 5432
    name: postgres
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-metrics
  namespace: ${PERF_NAMESPACE}
  labels:
    app: postgresql
spec:
  selector:
    app: postgresql
  ports:
  - port: 9187
    targetPort: 9187
    name: metrics
    protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgresql-metrics
  namespace: ${PERF_NAMESPACE}
  labels:
    app: postgresql
spec:
  endpoints:
  - path: /metrics
    port: metrics
    interval: 15s
  selector:
    matchLabels:
      app: postgresql
EOF

info "Waiting for PostgreSQL to be ready..."
oc rollout status deployment/postgresql -n "${PERF_NAMESPACE}" --timeout=180s 2>/dev/null || \
  warn "PostgreSQL not yet ready — check with: oc get pods -n ${PERF_NAMESPACE} -l app=postgresql"
ok "PostgreSQL deployed (sessions, config, inference cache)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. DEPLOY INFERENCE BACKEND (vLLM or llm-d Simulator)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${USE_SIMULATOR:-false}" == "true" ]]; then
  info "Deploying llm-d inference simulator (no GPU required)..."
  info "  Image: ${SIMULATOR_IMAGE}"
  info "  Mode:  ${SIMULATOR_MODE}, TTFT=${SIMULATOR_TTFT_MS}ms, ITL=${SIMULATOR_ITL_MS}ms"

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-inference
  namespace: ${PERF_NAMESPACE}
  labels:
    app: vllm-inference
    inference-backend: simulator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-inference
  template:
    metadata:
      labels:
        app: vllm-inference
        inference-backend: simulator
        sim-profile: "fast"
    spec:
      nodeSelector:
        node-role.kubernetes.io/loadgen-worker: ""
      containers:
      - name: simulator
        image: ${SIMULATOR_IMAGE}
        args:
        - "--model"
        - "${MODEL_ID}"
        - "--port"
        - "8000"
        - "--mode"
        - "${SIMULATOR_MODE}"
        - "--time-to-first-token"
        - "${SIMULATOR_TTFT_MS}ms"
        - "--inter-token-latency"
        - "${SIMULATOR_ITL_MS}ms"
        - "--max-model-len"
        - "${SIMULATOR_MAX_TOKENS}"
        - "--max-num-seqs"
        - "${SIMULATOR_MAX_NUM_SEQS:-4096}"
        ports:
        - containerPort: 8000
          name: http
        resources:
          requests:
            cpu: "1"
            memory: "512Mi"
          limits:
            cpu: "4"
            memory: "2Gi"
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-inference
  namespace: ${PERF_NAMESPACE}
  labels:
    app: vllm-inference
spec:
  selector:
    app: vllm-inference
  ports:
  - port: 8000
    targetPort: 8000
    name: http
EOF

  ok "Simulator Deployment + Service created (same service name: vllm-inference)"
  info "Simulator should be ready within seconds — no model download required."

else
  info "Deploying vLLM inference server on GPU node..."

  if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "HF_TOKEN is not set. If ${MODEL_ID} is a gated model, the download will fail."
    warn "Set HF_TOKEN in config.env or export it before running this script."
  fi

  oc create secret generic hf-token \
    --from-literal=token="${HF_TOKEN:-}" \
    -n "${PERF_NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-inference
  namespace: ${PERF_NAMESPACE}
  labels:
    app: vllm-inference
    inference-backend: vllm
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vllm-inference
  template:
    metadata:
      labels:
        app: vllm-inference
        inference-backend: vllm
    spec:
      nodeSelector:
        node-role.kubernetes.io/inference-worker: ""
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: vllm
        image: ${VLLM_IMAGE}
        args:
        - "--model"
        - "${MODEL_ID}"
        - "--tensor-parallel-size"
        - "${TENSOR_PARALLEL_SIZE}"
        - "--gpu-memory-utilization"
        - "${GPU_MEMORY_UTILIZATION}"
        - "--max-model-len"
        - "${MAX_MODEL_LEN}"
        - "--enable-auto-tool-choice"
        - "--tool-call-parser"
        - "${TOOL_CALL_PARSER}"
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: token
        - name: HF_HUB_OFFLINE
          value: "0"
        - name: HF_HOME
          value: "/root/.cache/huggingface"
        - name: TRANSFORMERS_CACHE
          value: "/root/.cache/huggingface"
        - name: XDG_CACHE_HOME
          value: "/root/.cache"
        resources:
          requests:
            nvidia.com/gpu: "${TENSOR_PARALLEL_SIZE}"
            cpu: "${VLLM_CPU_REQUEST:-4}"
            memory: "${VLLM_MEM_REQUEST:-16Gi}"
          limits:
            nvidia.com/gpu: "${TENSOR_PARALLEL_SIZE}"
            cpu: "${VLLM_CPU_LIMIT:-8}"
            memory: "${VLLM_MEM_LIMIT:-28Gi}"
        volumeMounts:
        - name: model-storage
          mountPath: /root/.cache/huggingface
        - name: shm
          mountPath: /dev/shm
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 300
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 120
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 600
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 20
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: model-storage
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: "${VLLM_SHM_SIZE:-8Gi}"
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-inference
  namespace: ${PERF_NAMESPACE}
  labels:
    app: vllm-inference
spec:
  selector:
    app: vllm-inference
  ports:
  - port: 8000
    targetPort: 8000
    name: http
EOF

  ok "vLLM Deployment + Service created"
  warn "Model download + loading may take 20-45 min for ${MODEL_ID}."
  warn "Monitor: oc logs -f deployment/vllm-inference -n ${PERF_NAMESPACE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. OGX — OGXServer CR (RHOAI 3.5 EA1+, ogx.io/v1beta1)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Creating OGXServer CR (operator-managed, RHOAI 3.5 EA1+)..."
info "  CR name:     ${OGX_SERVER_NAME}"
info "  Inference:   http://vllm-inference.${PERF_NAMESPACE}.svc.cluster.local:8000/v1"
info "  PostgreSQL:  postgresql:5432/${POSTGRESQL_DB}"

info "Waiting for OGXServer CRD to be available..."
OGX_CRD_READY=false
for i in $(seq 1 30); do
  if oc get crd ogxservers.ogx.io >/dev/null 2>&1; then
    ok "OGXServer CRD available"
    OGX_CRD_READY=true
    break
  fi
  echo -n "."
  sleep 10
done
echo ""

if [[ "$OGX_CRD_READY" != "true" ]]; then
  warn "OGXServer CRD not found after 5 minutes."
  warn "The ogx component in 03-install-operators.sh may need more time."
  warn "Check: oc get crd | grep ogx"
  warn "Skipping OGXServer CR creation — deploy manually later."
else
  PG_PASS=$(oc get secret postgresql-credentials -n "${PERF_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  # Create postgres connection secret with ogx.io/watch label
  oc create secret generic ogx-postgres-conn \
    --from-literal=connection-string="postgresql://${POSTGRESQL_USER}:${PG_PASS}@postgresql.${PERF_NAMESPACE}.svc.cluster.local:5432/${POSTGRESQL_DB}" \
    -n "${PERF_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label secret ogx-postgres-conn ogx.io/watch=true -n "${PERF_NAMESPACE}" --overwrite 2>/dev/null || true

  # Create config ConfigMap with ogx.io/watch label (overrideConfig)
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ogx-server-config
  namespace: ${PERF_NAMESPACE}
  labels:
    ogx.io/watch: "true"
data:
  config.yaml: |
    version: '2'
    image_name: rh-dev
    providers:
      inference:
        - provider_id: vllm-sim
          provider_type: remote::vllm
          config:
            base_url: http://vllm-inference.${PERF_NAMESPACE}.svc.cluster.local:8000/v1
            max_tokens: 4096
      responses:
        - provider_id: builtin
          provider_type: inline::builtin
          config:
            persistence:
              agent_state:
                backend: kv_pg
                namespace: agents
              responses:
                backend: sql_pg
                table_name: responses
      files:
        - provider_id: builtin
          provider_type: inline::localfs
          config:
            storage_dir: /tmp/ogx-files
            metadata_store:
              backend: sql_pg
              table_name: openai_files
    storage:
      backends:
        kv_pg:
          type: kv_postgres
          host: postgresql.${PERF_NAMESPACE}.svc.cluster.local
          port: 5432
          db: ${POSTGRESQL_DB}
          user: ${POSTGRESQL_USER}
          password: ${PG_PASS}
        sql_pg:
          type: sql_postgres
          host: postgresql.${PERF_NAMESPACE}.svc.cluster.local
          port: 5432
          db: ${POSTGRESQL_DB}
          user: ${POSTGRESQL_USER}
          password: ${PG_PASS}
      stores:
        metadata:
          backend: kv_pg
          namespace: registry
        inference:
          backend: sql_pg
          table_name: inference_store
        conversations:
          backend: sql_pg
          table_name: openai_conversations
        responses:
          backend: sql_pg
          table_name: responses
        prompts:
          backend: kv_pg
          namespace: prompts
        connectors:
          backend: sql_pg
          table_name: connectors
    metadata_store:
      type: postgres
      host: postgresql.${PERF_NAMESPACE}.svc.cluster.local
      port: 5432
      db: ${POSTGRESQL_DB}
      user: ${POSTGRESQL_USER}
      password: ${PG_PASS}
EOF

  oc apply -f - <<EOF
apiVersion: ogx.io/v1beta1
kind: OGXServer
metadata:
  name: ${OGX_SERVER_NAME}
  namespace: ${PERF_NAMESPACE}
spec:
  distribution:
    name: rh-dev
  overrideConfig:
    name: ogx-server-config
    key: config.yaml
  workload:
    replicas: 1
    overrides:
      env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector-collector.${PERF_NAMESPACE}.svc.cluster.local:4318"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_SERVICE_NAME
          value: "ogx"
        - name: VLLM_URL
          value: "http://vllm-inference.${PERF_NAMESPACE}.svc.cluster.local:8000/v1"
        - name: INFERENCE_MODEL
          value: "${MODEL_ID}"
        - name: POSTGRES_HOST
          value: "postgresql.${PERF_NAMESPACE}.svc.cluster.local"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_DB
          value: "${POSTGRESQL_DB}"
        - name: POSTGRES_USER
          value: "${POSTGRESQL_USER}"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: password
EOF

  ok "OGXServer CR created"

  # Wait for the OGX deployment to appear
  info "Waiting for OGX deployment to appear (up to 3 minutes)..."
  OGX_DEPLOY=""
  for i in $(seq 1 36); do
    OGX_DEPLOY=$(oc get deployment -n "${PERF_NAMESPACE}" -l app=ogx-server \
      --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)
    if [[ -n "$OGX_DEPLOY" ]]; then
      break
    fi
    # Also check the name directly (operator names it after the CR)
    if oc get deployment "${OGX_SERVER_NAME}" -n "${PERF_NAMESPACE}" >/dev/null 2>&1; then
      OGX_DEPLOY="${OGX_SERVER_NAME}"
      break
    fi
    echo -n "."
    sleep 5
  done
  echo ""

  if [[ -n "$OGX_DEPLOY" ]]; then
    info "Waiting for OGX pod to be ready..."
    oc rollout status deployment/"${OGX_DEPLOY}" -n "${PERF_NAMESPACE}" --timeout=180s 2>/dev/null || \
      warn "OGX not yet ready — check: oc get pods -n ${PERF_NAMESPACE} -l app=ogx-server"
    ok "OGX deployment is ready"
  else
    warn "OGX deployment not found after 3 minutes."
    warn "The operator may need more time. Check: oc get pods -n ${PERF_NAMESPACE}"
  fi

  OGX_SVC_NAME="${OGX_SERVER_NAME}-service"
  if oc get svc "${OGX_SVC_NAME}" -n "${PERF_NAMESPACE}" >/dev/null 2>&1; then
    ok "OGX service: ${OGX_SVC_NAME} (port 8321)"
  else
    warn "OGX service ${OGX_SVC_NAME} not yet created — verify after deployment completes."
  fi
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. DEPLOY OPENTELEMETRY COLLECTOR + SERVICE MONITOR
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${OTEL_ENABLED}" == "true" ]]; then
  info "Deploying OpenTelemetry Collector for metrics + traces..."

  oc apply -f - <<EOF
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: ${PERF_NAMESPACE}
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        send_batch_size: 1024
        timeout: 5s
      memory_limiter:
        check_interval: 5s
        limit_mib: 256
    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
      debug:
        verbosity: basic
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
EOF

  ok "OTel Collector deployed (metrics → Prometheus, traces + logs → debug)"

  info "Creating ServiceMonitor so Prometheus scrapes OTel Collector metrics..."

  oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-metrics
  namespace: ${PERF_NAMESPACE}
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  endpoints:
  - port: prometheus
    interval: 30s
    path: /metrics
  selector:
    matchLabels:
      app.kubernetes.io/component: opentelemetry-collector
      app.kubernetes.io/instance: ${PERF_NAMESPACE}.otel-collector
EOF

  ok "ServiceMonitor created — Prometheus will scrape OTel metrics"

  info "Creating ServiceMonitor for vLLM Prometheus endpoint..."
  oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-inference-metrics
  namespace: ${PERF_NAMESPACE}
  labels:
    app: vllm-inference
spec:
  endpoints:
  - path: /metrics
    port: http
    interval: 15s
  selector:
    matchLabels:
      app: vllm-inference
EOF
  ok "vLLM ServiceMonitor created (OGX metrics flow through OTel Collector)"

  info "OGX exports OTel to:"
  info "  OTEL endpoint: http://otel-collector-collector.${PERF_NAMESPACE}.svc:4318 (HTTP/protobuf)"
  info "  Metrics flow: OGX → OTel Collector → Prometheus"
else
  info "OpenTelemetry disabled (OTEL_ENABLED=${OTEL_ENABLED}) — skipping collector deployment"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. DEPLOY MCP SERVERS  
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${MCP_KUBERNETES_ENABLED}" == "true" ]]; then
  info "Deploying Kubernetes MCP server..."

  # Service account + RBAC for K8s MCP server
  oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubernetes-mcp-sa
  namespace: ${PERF_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kubernetes-mcp-role
  namespace: ${PERF_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "events", "namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubernetes-mcp-rolebinding
  namespace: ${PERF_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: kubernetes-mcp-sa
  namespace: ${PERF_NAMESPACE}
roleRef:
  kind: Role
  name: kubernetes-mcp-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-mcp-server
  namespace: ${PERF_NAMESPACE}
  labels:
    app: kubernetes-mcp-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kubernetes-mcp-server
  template:
    metadata:
      labels:
        app: kubernetes-mcp-server
    spec:
      nodeSelector:
        node-role.kubernetes.io/ogx-worker: ""
      serviceAccountName: kubernetes-mcp-sa
      containers:
      - name: mcp
        image: ${MCP_KUBERNETES_IMAGE}
        ports:
        - containerPort: 8080
          name: mcp
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-mcp-server
  namespace: ${PERF_NAMESPACE}
  labels:
    app: kubernetes-mcp-server
spec:
  selector:
    app: kubernetes-mcp-server
  ports:
  - port: 8080
    targetPort: 8080
    name: mcp
EOF

  ok "Kubernetes MCP server deployed"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SUMMARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "============================================"
echo "  Stack Deployment Summary"
echo "============================================"
info "Pods in ${PERF_NAMESPACE}:"
oc get pods -n "${PERF_NAMESPACE}" -o wide 2>/dev/null || true
echo ""
info "PVCs in ${PERF_NAMESPACE}:"
oc get pvc -n "${PERF_NAMESPACE}" 2>/dev/null || true
echo ""
info "Services in ${PERF_NAMESPACE}:"
oc get svc -n "${PERF_NAMESPACE}" 2>/dev/null || true
echo ""

if [[ "${USE_SIMULATOR:-false}" == "true" ]]; then
  info "Inference backend: llm-d simulator (no GPU, ready in seconds)"
else
  warn "vLLM model loading takes 10-20 minutes for a 70B model."
  warn "Monitor vLLM: oc logs -f deployment/vllm-inference -n ${PERF_NAMESPACE}"
fi
info "OGX: ${LLAMA_STACK_URL} (OGXServer CR in ${PERF_NAMESPACE})"
echo ""
info "Next step: ./05-validate.sh"

