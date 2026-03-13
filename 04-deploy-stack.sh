#!/usr/bin/env bash
# ============================================================================
# 04-deploy-stack.sh — Deploy PostgreSQL, Llama Stack, and MCP servers
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

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
        node-role.kubernetes.io/app-worker: ""
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
    spec:
      nodeSelector:
        node-role.kubernetes.io/inference-worker: ""
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
        - "--ttft"
        - "${SIMULATOR_TTFT_MS}"
        - "--itl"
        - "${SIMULATOR_ITL_MS}"
        - "--max-tokens"
        - "${SIMULATOR_MAX_TOKENS}"
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
            cpu: "16"
            memory: "200Gi"
          limits:
            nvidia.com/gpu: "${TENSOR_PARALLEL_SIZE}"
            cpu: "64"
            memory: "600Gi"
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
          sizeLimit: "64Gi"
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
# 5. DEPLOY LLAMA STACK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
info "Deploying Llama Stack (ODH distribution, remote-vllm provider)..."

OTEL_ENDPOINT="http://otel-collector-collector.${PERF_NAMESPACE}.svc:4317"

# The ODH Llama Stack image ships a default config that registers an embedding
# model referencing a "vllm-embedding" provider which doesn't exist in our
# single-vLLM setup. We supply a corrected config via ConfigMap.
PG_PASSWORD_LITERAL=$(oc get secret postgresql-credentials -n "${PERF_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
PG_USER_LITERAL=$(oc get secret postgresql-credentials -n "${PERF_NAMESPACE}" -o jsonpath='{.data.username}' | base64 -d)
PG_DB_LITERAL=$(oc get secret postgresql-credentials -n "${PERF_NAMESPACE}" -o jsonpath='{.data.database}' | base64 -d)

cat <<EOCFG > /tmp/llama-stack-config.yaml
version: 2
distro_name: rh
image_name: rh
apis:
- agents
- batches
- datasetio
- eval
- inference
- safety
- scoring
- tool_runtime
- vector_io
- files
connectors: []
providers:
  agents:
  - config:
      persistence:
        agent_state:
          backend: kv_default
          namespace: agents::meta_reference
        responses:
          backend: sql_default
          max_write_queue_size: 10000
          num_writers: 4
          table_name: agents_responses
    provider_id: meta-reference
    provider_type: inline::meta-reference
  batches:
  - config:
      kvstore:
        backend: kv_default
        namespace: batches
    provider_id: reference
    provider_type: inline::reference
  datasetio:
  - config:
      kvstore:
        backend: kv_default
        namespace: datasetio::huggingface
    provider_id: huggingface
    provider_type: remote::huggingface
  - config:
      kvstore:
        backend: kv_default
        namespace: datasetio::localfs
    provider_id: localfs
    provider_type: inline::localfs
  eval:
  - config:
      base_url: http://vllm-inference.${PERF_NAMESPACE}.svc:8000/v1
      use_k8s: true
    module: llama_stack_provider_lmeval==0.5.0
    provider_id: trustyai_lmeval
    provider_type: remote::trustyai_lmeval
  files:
  - config:
      metadata_store:
        backend: sql_default
        table_name: files_metadata
      storage_dir: /opt/app-root/src/.llama/distributions/rh/files
    provider_id: meta-reference-files
    provider_type: inline::localfs
  inference:
  - config:
      api_token: ""
      base_url: http://vllm-inference.${PERF_NAMESPACE}.svc:8000/v1
      max_tokens: 4096
      tls_verify: true
    provider_id: vllm-inference
    provider_type: remote::vllm
  safety:
  - config:
      shields: {}
    module: llama_stack_provider_trustyai_fms==0.4.0
    provider_id: trustyai_fms
    provider_type: remote::trustyai_fms
  scoring:
  - config: {}
    provider_id: basic
    provider_type: inline::basic
  - config: {}
    provider_id: llm-as-judge
    provider_type: inline::llm-as-judge
  - config:
      openai_api_key: ""
    provider_id: braintrust
    provider_type: inline::braintrust
  tool_runtime:
  - config:
      api_key: ""
      max_results: 3
    provider_id: brave-search
    provider_type: remote::brave-search
  - config:
      api_key: ""
      max_results: 3
    provider_id: tavily-search
    provider_type: remote::tavily-search
  - config: {}
    provider_id: rag-runtime
    provider_type: inline::rag-runtime
  - config: {}
    provider_id: model-context-protocol
    provider_type: remote::model-context-protocol
  vector_io:
  - config:
      db_path: /opt/app-root/src/.llama/distributions/rh/milvus.db
      persistence:
        backend: kv_default
        namespace: vector_io::milvus
    provider_id: milvus
    provider_type: inline::milvus
models: []
shields: []
scoring_fns: []
server:
  port: 8321
  tls_certfile: null
  tls_keyfile: null
  workers: 1
storage:
  backends:
    kv_default:
      db: ${PG_DB_LITERAL}
      host: postgresql
      password: "${PG_PASSWORD_LITERAL}"
      port: 5432
      table_name: llamastack_kvstore
      type: kv_postgres
      user: ${PG_USER_LITERAL}
    sql_default:
      db: ${PG_DB_LITERAL}
      host: postgresql
      password: "${PG_PASSWORD_LITERAL}"
      port: 5432
      type: sql_postgres
      user: ${PG_USER_LITERAL}
  stores:
    connectors:
      backend: kv_default
      namespace: connectors
    conversations:
      backend: sql_default
      table_name: openai_conversations
    inference:
      backend: sql_default
      max_write_queue_size: 10000
      num_writers: 4
      table_name: inference_store
    metadata:
      backend: kv_default
      namespace: registry
    prompts:
      backend: kv_default
      namespace: prompts
EOCFG

oc create configmap llama-stack-config \
  --from-file=config.yaml=/tmp/llama-stack-config.yaml \
  -n "${PERF_NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/llama-stack-config.yaml

ok "Llama Stack config ConfigMap created (embedding model removed)"

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-stack
  namespace: ${PERF_NAMESPACE}
  labels:
    app: llama-stack
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llama-stack
  template:
    metadata:
      labels:
        app: llama-stack
    spec:
      nodeSelector:
        node-role.kubernetes.io/app-worker: ""
      containers:
      - name: llama-stack
        image: ${LLAMA_STACK_IMAGE}
        ports:
        - containerPort: 8321
          name: http
        env:
        - name: LLAMA_STACK_PORT
          value: "8321"
        - name: VLLM_URL
          value: "http://vllm-inference.${PERF_NAMESPACE}.svc:8000/v1"
        - name: POSTGRES_HOST
          value: "postgresql"
        - name: POSTGRES_PORT
          value: "5432"
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
        - name: INFERENCE_MODEL
          value: "${MODEL_ID}"
        - name: OTEL_SERVICE_NAME
          value: "llama-stack"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "${OTEL_ENDPOINT}"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "grpc"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: TELEMETRY_ENABLED
          value: "true"
        resources:
          requests:
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "4"
            memory: "8Gi"
        volumeMounts:
        - name: config
          mountPath: /opt/app-root/config.yaml
          subPath: config.yaml
        readinessProbe:
          httpGet:
            path: /v1/health
            port: 8321
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        livenessProbe:
          httpGet:
            path: /v1/health
            port: 8321
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
      volumes:
      - name: config
        configMap:
          name: llama-stack-config
---
apiVersion: v1
kind: Service
metadata:
  name: llama-stack
  namespace: ${PERF_NAMESPACE}
  labels:
    app: llama-stack
spec:
  selector:
    app: llama-stack
  ports:
  - port: 8321
    targetPort: 8321
    name: http
EOF

ok "Llama Stack Deployment + Service created"
info "Llama Stack API will be available at: http://llama-stack.${PERF_NAMESPACE}.svc:8321"

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
  ok "vLLM ServiceMonitor created (Llama Stack metrics flow through OTel Collector)"

  info "Llama Stack exports OTel to:"
  info "  OTEL endpoint: http://otel-collector-collector.${PERF_NAMESPACE}.svc:4317 (gRPC)"
  info "  Metrics flow: Llama Stack → OTel Collector → Prometheus"
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
        node-role.kubernetes.io/app-worker: ""
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
warn "Monitor Llama Stack: oc logs -f deployment/llama-stack -n ${PERF_NAMESPACE}"
echo ""
info "Next step: ./05-validate.sh"

