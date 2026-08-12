#!/usr/bin/env bash
# ============================================================================
# sim-profile.sh — Switch the simulator delay profile between test runs
#
# Profiles (from RHAIIS benchmark data, 1k/1k workload):
#   fast       130ms TTFT,  7ms ITL  — Best-case modern GPU
#   moderate   400ms TTFT, 30ms ITL  — Mid-range production inference
#   realistic 3700ms TTFT, 85ms ITL  — Slow inference, I/O-bound stress
#
# Usage:
#   ./sim-profile.sh fast
#   ./sim-profile.sh moderate
#   ./sim-profile.sh realistic
#   ./sim-profile.sh status          — show current profile
#   ./sim-profile.sh custom 200 15   — custom TTFT(ms) and ITL(ms)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_ENV:-${SCRIPT_DIR}/config.env}"

DEPLOY_NAME="vllm-inference"

usage() {
  echo "Usage: $0 {fast|moderate|realistic|status|custom <ttft_ms> <itl_ms>}"
  echo ""
  echo "Profiles:"
  echo "  fast        130ms TTFT,   7ms ITL"
  echo "  moderate    400ms TTFT,  30ms ITL"
  echo "  realistic  3700ms TTFT,  85ms ITL"
  echo "  custom      <ttft_ms>  <itl_ms>"
  echo "  status      show current simulator args"
  exit 1
}

[[ $# -lt 1 ]] && usage

PROFILE="$1"

case "$PROFILE" in
  fast)
    TTFT_MS=130
    ITL_MS=7
    ;;
  moderate)
    TTFT_MS=400
    ITL_MS=30
    ;;
  realistic)
    TTFT_MS=3700
    ITL_MS=85
    ;;
  custom)
    [[ $# -lt 3 ]] && { err "custom requires <ttft_ms> <itl_ms>"; usage; }
    TTFT_MS="$2"
    ITL_MS="$3"
    PROFILE="custom-${TTFT_MS}ms-${ITL_MS}ms"
    ;;
  status)
    info "Current simulator deployment args:"
    oc get deployment "${DEPLOY_NAME}" -n "${PERF_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | \
      python3 -m json.tool 2>/dev/null || \
      oc get deployment "${DEPLOY_NAME}" -n "${PERF_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].args}'
    echo ""
    info "Pod status:"
    oc get pods -n "${PERF_NAMESPACE}" -l app=vllm-inference -o wide
    exit 0
    ;;
  *)
    usage
    ;;
esac

echo ""
echo "============================================"
echo "  Switching Simulator Profile"
echo "  Profile:   ${PROFILE}"
echo "  TTFT:      ${TTFT_MS}ms"
echo "  ITL:       ${ITL_MS}ms"
echo "  Namespace: ${PERF_NAMESPACE}"
echo "============================================"
echo ""

oc whoami >/dev/null 2>&1 || bail "Cannot connect to cluster. Set KUBECONFIG=${KUBECONFIG}"

# Patch the deployment args with the new delay profile.
# The simulator accepts: --model M --port 8000 --mode MODE --time-to-first-token Xms --inter-token-latency Yms --max-model-len N
info "Patching deployment/${DEPLOY_NAME} with TTFT=${TTFT_MS}ms, ITL=${ITL_MS}ms..."

oc patch deployment "${DEPLOY_NAME}" -n "${PERF_NAMESPACE}" \
  --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/metadata/labels/sim-profile\",\"value\":\"${PROFILE}\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[
      \"--model\",\"${MODEL_ID}\",
      \"--port\",\"8000\",
      \"--mode\",\"${SIMULATOR_MODE}\",
      \"--time-to-first-token\",\"${TTFT_MS}ms\",
      \"--inter-token-latency\",\"${ITL_MS}ms\",
      \"--max-model-len\",\"${SIMULATOR_MAX_TOKENS}\"
    ]}
  ]"

ok "Deployment patched — rolling out new pod"

info "Waiting for rollout to complete..."
oc rollout status deployment/"${DEPLOY_NAME}" -n "${PERF_NAMESPACE}" --timeout=120s

ok "Simulator is running with profile: ${PROFILE} (TTFT=${TTFT_MS}ms, ITL=${ITL_MS}ms)"
echo ""

# Verify the pod is healthy
info "Verifying simulator health..."
SIM_POD=$(oc get pod -l app=vllm-inference -n "${PERF_NAMESPACE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$SIM_POD" ]]; then
  HEALTH=$(oc exec "${SIM_POD}" -n "${PERF_NAMESPACE}" -- \
    curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/health 2>/dev/null || echo "000")
  if [[ "$HEALTH" == "200" ]]; then
    ok "Simulator health check passed"
  else
    warn "Simulator health check returned ${HEALTH} — may still be starting"
  fi
fi

echo ""
info "Ready for benchmarking with profile: ${PROFILE}"
info "  TTFT: ${TTFT_MS}ms  |  ITL: ${ITL_MS}ms"
echo ""
