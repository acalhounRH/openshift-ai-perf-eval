#!/usr/bin/env bash
# ============================================================================
# run_full_suite.sh — Run the full OGX benchmark suite across all sim profiles
#
# Cycles through simulator delay profiles (fast, moderate, realistic),
# patching the vLLM simulator deployment for each, then runs all three
# methods (response, chat, direct) with all payloads.
#
# Designed to run ON the benchmark-runner pod via nohup so it survives
# network disconnects. Copy this to the pod and execute:
#
#   nohup bash /scripts/run_full_suite.sh > /tmp/results/full-suite.log 2>&1 &
#
# Monitor:  tail -f /tmp/results/full-suite.log
# ============================================================================
set -euo pipefail

export PYTHONPATH="/tmp/guidellm-upgrade:/tmp/pylib:${PYTHONPATH:-}"
export PATH="/tmp/guidellm-upgrade/bin:${PATH}"
unset GUIDELLM_MAX_REQUESTS GUIDELLM_DATA GUIDELLM_OUTPUT_PATH \
      GUIDELLM_MODEL GUIDELLM_RATE_TYPE GUIDELLM_TARGET GUIDELLM_MAX_SECONDS \
      2>/dev/null || true

NAMESPACE="${PERF_NAMESPACE:-perf-testing}"
METHODS=(response chat direct)
BENCH_SCRIPT="/scripts/run_guidellm_bench.py"

# Simulator delay profiles from the test plan
declare -A PROFILE_TTFT=( [fast]=130 [moderate]=400 [realistic]=3700 )
declare -A PROFILE_ITL=(  [fast]=7   [moderate]=30  [realistic]=85   )
PROFILES=(fast moderate realistic)

switch_sim_profile() {
    local profile="$1"
    local ttft="${PROFILE_TTFT[$profile]}"
    local itl="${PROFILE_ITL[$profile]}"

    echo ""
    echo "###################################################################"
    echo "  Switching simulator to profile: ${profile}"
    echo "  TTFT=${ttft}ms  ITL=${itl}ms"
    echo "###################################################################"
    echo ""

    # Patch the deployment args via the Kubernetes API
    python3 -c "
import urllib.request, json, ssl, os

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read().strip()
ns = '${NAMESPACE}'
api = 'https://kubernetes.default.svc'

patch = {
    'spec': {
        'template': {
            'metadata': {
                'labels': {
                    'sim-profile': '${profile}'
                }
            },
            'spec': {
                'containers': [{
                    'name': 'simulator',
                    'args': [
                        '--model', 'simulator',
                        '--port', '8000',
                        '--mode', 'random',
                        '--time-to-first-token', '${ttft}ms',
                        '--inter-token-latency', '${itl}ms',
                        '--max-model-len', '8192',
                        '--max-num-seqs', '4096'
                    ]
                }]
            }
        }
    }
}

url = f'{api}/apis/apps/v1/namespaces/{ns}/deployments/vllm-inference'
data = json.dumps(patch).encode()
req = urllib.request.Request(url, data=data, method='PATCH')
req.add_header('Authorization', f'Bearer {token}')
req.add_header('Content-Type', 'application/strategic-merge-patch+json')
resp = urllib.request.urlopen(req, timeout=15, context=ctx)
print(f'  Patch response: {resp.status}')
"

    echo "  Waiting for rollout..."
    local attempts=0
    while true; do
        attempts=$((attempts + 1))
        if python3 -c "
import sys, urllib.request
try:
    r = urllib.request.urlopen('http://vllm-inference:8000/health', timeout=5)
    sys.exit(0 if r.status == 200 else 1)
except SystemExit as e:
    sys.exit(e.code)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
            echo "  vLLM healthy"
            break
        fi
        if [ "$attempts" -gt 60 ]; then
            echo "  ERROR: vLLM not healthy after 60 attempts"
            return 1
        fi
        echo "  attempt ${attempts}: waiting..."
        sleep 5
    done
    echo "  Simulator ready with profile: ${profile}"
}

# ── Main ──

echo "============================================================"
echo "  OGX Full Benchmark Suite"
echo "  Profiles:  ${PROFILES[*]}"
echo "  Methods:   ${METHODS[*]}"
echo "  Payloads:  all (small, medium, large)"
echo "  Started:   $(date)"
echo "============================================================"
echo ""

total_phases=0
completed_phases=0
failed_phases=0

for profile in "${PROFILES[@]}"; do
    switch_sim_profile "$profile"

    for method in "${METHODS[@]}"; do
        total_phases=$((total_phases + 1))
        echo ""
        echo "============================================================"
        echo "  Phase: ${method} / ${profile}"
        echo "  Time:  $(date)"
        echo "============================================================"

        if python3 "$BENCH_SCRIPT" \
            --method "$method" \
            --sim-profile "$profile" \
            --payload all; then
            completed_phases=$((completed_phases + 1))
            echo "  Phase ${method}/${profile}: PASSED"
        else
            failed_phases=$((failed_phases + 1))
            echo "  Phase ${method}/${profile}: FAILED (continuing)"
        fi
    done
done

echo ""
echo "============================================================"
echo "  FULL SUITE COMPLETE"
echo "  Total phases:     ${total_phases}"
echo "  Completed:        ${completed_phases}"
echo "  Failed:           ${failed_phases}"
echo "  Finished:         $(date)"
echo "============================================================"
