#!/usr/bin/env bash
# test-precedence.sh — automated test runner for the multi-layer precedence system.
# Runs all tests sequentially and prints a report at the end.
#
# Usage:
#   ./scripts/test-precedence.sh [NAMESPACE]
#
# Default namespace: team1

set -euo pipefail

NS="${1:-team1}"
WEBHOOK_NS="kagenti-webhook-system"
CLUSTER="${CLUSTER:-kagenti}"
FG_CM="kagenti-webhook-feature-gates"
WAIT_SECS=12
HOTRELOAD_MAX_WAIT=30   # Reduced from 120s because kubelet syncFrequency is set to 10s during tests

# Container names (must match Go constants)
ENVOY="envoy-proxy"
PROXY_INIT="proxy-init"
SPIFFE="spiffe-helper"
CLIENT_REG="kagenti-client-registration"

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── State ────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
declare -a RESULTS=()
declare -a DEPLOYMENTS=()

# ── Helpers ──────────────────────────────────────────────────────────

log()  { echo -e "${CYAN}[TEST]${NC} $*"; }
pass() { echo -e "  ${GREEN}PASS${NC} $*"; PASS=$((PASS+1)); RESULTS+=("PASS  $*"); }
fail() { echo -e "  ${RED}FAIL${NC} $*"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $*"); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $*"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $*"); }
separator() { echo -e "${BOLD}────────────────────────────────────────────────────${NC}"; }

# Speed up kubelet ConfigMap volume sync to 10s.
# Patches the kubelet-config ConfigMap via kubectl, then pipes the updated
# config to the node using tee (no direct YAML file editing).
# Requires: jq
speed_up_kubelet() {
  log "Setting kubelet syncFrequency=10s via kubelet-config ConfigMap patch..."

  # 1. Patch the ConfigMap: strip any existing syncFrequency, append 10s
  kubectl get configmap kubelet-config -n kube-system -o json \
    | jq '.data.kubelet |= (split("\n")
        | map(select(startswith("syncFrequency:") | not))
        + ["syncFrequency: 10s"]
        | join("\n"))' \
    | kubectl apply -f -

  # 2. Write the updated config to the node and restart kubelet
  kubectl get configmap kubelet-config -n kube-system \
    -o jsonpath='{.data.kubelet}' \
    | docker exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
  docker exec "${CLUSTER}-control-plane" systemctl restart kubelet

  sleep 5
  log "Kubelet restarted with syncFrequency=10s"
}

# Reset kubelet syncFrequency to default by removing the override from the
# kubelet-config ConfigMap and syncing back to the node.
reset_kubelet() {
  log "Resetting kubelet syncFrequency to default via kubelet-config ConfigMap patch..."

  # 1. Remove syncFrequency from the ConfigMap
  kubectl get configmap kubelet-config -n kube-system -o json \
    | jq '.data.kubelet |= (split("\n")
        | map(select(startswith("syncFrequency:") | not))
        | join("\n"))' \
    | kubectl apply -f -

  # 2. Write the restored config to the node and restart kubelet
  kubectl get configmap kubelet-config -n kube-system \
    -o jsonpath='{.data.kubelet}' \
    | docker exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
  docker exec "${CLUSTER}-control-plane" systemctl restart kubelet

  sleep 5
  log "Kubelet reset to default syncFrequency"
}

# Deploy a test workload. Extra args are additional label lines (already indented).
deploy() {
  local name=$1; shift
  local extra_labels=""
  for lbl in "$@"; do
    extra_labels="${extra_labels}
        ${lbl}"
  done

  # Delete first to ensure a clean CREATE (not UPDATE) so the webhook always runs
  kubectl delete deployment -n "${NS}" "${name}" --ignore-not-found >/dev/null 2>&1
  sleep 2

  kubectl apply -n "${NS}" -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
        kagenti.io/type: agent${extra_labels}
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF
  DEPLOYMENTS+=("${name}")
  sleep "${WAIT_SECS}"
}

# Return space-separated list of init container names for a pod.
get_init_containers() {
  kubectl get pods -n "${NS}" -l "app=$1" -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null || true
}

# Return space-separated list of container names for a pod.
get_containers() {
  kubectl get pods -n "${NS}" -l "app=$1" -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true
}

# Check if a name exists in a space-separated list.
has() {
  local needle=$1 haystack=$2
  [[ " ${haystack} " == *" ${needle} "* ]]
}

# Assert a container IS present. $1=test name, $2=container name, $3=list
assert_has() {
  if has "$2" "$3"; then
    pass "$1: has $2"
  else
    fail "$1: expected $2 but not found (got: $3)"
  fi
}

# Assert a container is NOT present.
assert_missing() {
  if has "$2" "$3"; then
    fail "$1: expected NO $2 but found it (got: $3)"
  else
    pass "$1: no $2 (correct)"
  fi
}

# Set feature gates via ConfigMap patch, then wait for the webhook to confirm reload.
set_feature_gates() {
  local global=$1 envoy=$2 spiffe=$3 clientreg=$4

  # Record a timestamp BEFORE patching (RFC3339 UTC, required by kubectl --since-time).
  # This ensures we only match a "Feature gates reloaded" log entry that appeared
  # AFTER the ConfigMap patch — not a stale entry from a previous set_feature_gates call.
  local before_ts
  before_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  kubectl patch configmap "${FG_CM}" -n "${WEBHOOK_NS}" --type=merge \
    -p "{\"data\":{\"feature-gates.yaml\":\"globalEnabled: ${global}\nenvoyProxy: ${envoy}\nspiffeHelper: ${spiffe}\nclientRegistration: ${clientreg}\n\"}}" >/dev/null
  log "Feature gates set: global=${global} envoy=${envoy} spiffe=${spiffe} clientreg=${clientreg}"

  # Poll logs for "Feature gates reloaded successfully" (emitted by feature_gate_loader.go)
  # using --since-time to filter out reload messages from previous calls.
  # Kubernetes ConfigMap volume propagation can take up to 1-2 minutes.
  log "Waiting for hot-reload (up to ${HOTRELOAD_MAX_WAIT}s)..."
  local waited=0
  while [ "${waited}" -lt "${HOTRELOAD_MAX_WAIT}" ]; do
    if kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager \
        --since-time="${before_ts}" 2>/dev/null \
        | grep -q "Feature gates reloaded"; then
      log "Hot-reload confirmed after ${waited}s"
      sleep 2  # brief settle time
      return
    fi
    sleep 5
    waited=$((waited + 5))
    printf "  ... %ds\r" "${waited}"
  done
  echo ""
  log "WARNING: Hot-reload not confirmed after ${HOTRELOAD_MAX_WAIT}s — proceeding anyway"
}

# Reset feature gates to all enabled.
reset_feature_gates() {
  set_feature_gates true true true true
}

# ── Preconditions ────────────────────────────────────────────────────

echo ""
separator
echo -e "${BOLD}  Precedence System — Automated Test Runner${NC}"
separator
echo ""

log "Namespace: ${NS}"
log "Webhook namespace: ${WEBHOOK_NS}"
log "Kind cluster: ${CLUSTER}"
echo ""

# Ensure namespace is opted in
kubectl label namespace "${NS}" kagenti-enabled=true --overwrite >/dev/null 2>&1
log "Namespace ${NS} labelled kagenti-enabled=true"

# Ensure feature gates are all enabled at start.
# Must run BEFORE speed_up_kubelet: reset_feature_gates waits for a hot-reload
# log event, and the kubelet needs to already be in a stable sync state for
# that wait to complete within the timeout.
reset_feature_gates

# Speed up ConfigMap propagation for the duration of the test run.
# This runs AFTER the initial reset so it doesn't race with post-restart
# kubelet re-initialization.
speed_up_kubelet

# ── Test 1: Config Loading ───────────────────────────────────────────

separator
log "Test 1: Verify startup & config loading"

# Startup banners are logged once at pod start; use a large tail to ensure they're captured
# even when the pod has been running for a while and has many subsequent log lines.
CONFIG_LOGS=$(kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager --tail=5000 2>/dev/null || true)

if echo "${CONFIG_LOGS}" | grep -q "PLATFORM CONFIGURATION"; then
  pass "Test 1: Platform configuration banner found in logs"
else
  # Fall back to checking the older log format
  if echo "${CONFIG_LOGS}" | grep -q "Platform config loaded"; then
    pass "Test 1: Platform config loaded (older log format)"
  else
    fail "Test 1: Platform configuration NOT found in logs"
  fi
fi

if echo "${CONFIG_LOGS}" | grep -q "FEATURE GATES"; then
  pass "Test 1: Feature gates banner found in logs"
else
  if echo "${CONFIG_LOGS}" | grep -q "Feature gates"; then
    pass "Test 1: Feature gates loaded (older log format)"
  else
    fail "Test 1: Feature gates NOT found in logs"
  fi
fi

# ── Test 2: Baseline — All Sidecars ─────────────────────────────────

separator
log "Test 2: Baseline — all sidecars injected by default (no SPIRE label needed)"

deploy t2-baseline

INIT=$(get_init_containers t2-baseline)
CONT=$(get_containers t2-baseline)

assert_has     "Test 2" "${PROXY_INIT}"  "${INIT}"
assert_has     "Test 2" "${ENVOY}"       "${CONT}"
assert_has     "Test 2" "${SPIFFE}"      "${CONT}"
assert_has     "Test 2" "${CLIENT_REG}"  "${CONT}"

# ── Test 3: Disable Envoy Feature Gate ───────────────────────────────

separator
log "Test 3: Per-sidecar feature gate — disable envoy-proxy"

set_feature_gates true false true true
deploy t3-no-envoy

INIT=$(get_init_containers t3-no-envoy)
CONT=$(get_containers t3-no-envoy)

assert_missing "Test 3" "${PROXY_INIT}"  "${INIT}"
assert_missing "Test 3" "${ENVOY}"       "${CONT}"
assert_has     "Test 3" "${CLIENT_REG}"  "${CONT}"

reset_feature_gates

# ── Test 4: Workload Label — Disable Spiffe-Helper ───────────────────

separator
log "Test 4: Workload label opt-out — disable spiffe-helper (kagenti.io/spiffe-helper-inject=false)"

deploy t4-no-spiffe 'kagenti.io/spiffe-helper-inject: "false"'

INIT=$(get_init_containers t4-no-spiffe)
CONT=$(get_containers t4-no-spiffe)

assert_has     "Test 4" "${PROXY_INIT}"  "${INIT}"
assert_has     "Test 4" "${ENVOY}"       "${CONT}"
assert_missing "Test 4" "${SPIFFE}"      "${CONT}"
assert_has     "Test 4" "${CLIENT_REG}"  "${CONT}"

# ── Test 5: SPIRE Opt-Out Label ───────────────────────────────────────

separator
log "Test 5: SPIRE opt-out label — kagenti.io/spire=disabled skips spiffe-helper"

deploy t5-spire-optout 'kagenti.io/spire: "disabled"'

INIT=$(get_init_containers t5-spire-optout)
CONT=$(get_containers t5-spire-optout)

assert_has     "Test 5" "${PROXY_INIT}"  "${INIT}"
assert_has     "Test 5" "${ENVOY}"       "${CONT}"
assert_missing "Test 5" "${SPIFFE}"      "${CONT}"
assert_has     "Test 5" "${CLIENT_REG}"  "${CONT}"

# ── Test 6: Global Kill Switch ───────────────────────────────────────

separator
log "Test 6: Global kill switch OFF"

set_feature_gates false true true true
deploy t6-global-off

INIT=$(get_init_containers t6-global-off)
CONT=$(get_containers t6-global-off)

assert_missing "Test 6" "${PROXY_INIT}"  "${INIT}"
assert_missing "Test 6" "${ENVOY}"       "${CONT}"
assert_missing "Test 6" "${SPIFFE}"      "${CONT}"
assert_missing "Test 6" "${CLIENT_REG}"  "${CONT}"

reset_feature_gates

# ── Test 7: Namespace Not Opted In ───────────────────────────────────

separator
log "Test 7: Namespace not opted in"

NO_OPTIN_NS="test-precedence-no-optin"
kubectl create namespace "${NO_OPTIN_NS}" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
# Intentionally do NOT label with kagenti-enabled=true

# Deploy directly (can't use deploy() since different namespace)
kubectl delete deployment -n "${NO_OPTIN_NS}" t7-no-optin --ignore-not-found >/dev/null 2>&1
sleep 2
kubectl apply -n "${NO_OPTIN_NS}" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t7-no-optin
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: t7-no-optin
  template:
    metadata:
      labels:
        app: t7-no-optin
        kagenti.io/type: agent
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF
sleep "${WAIT_SECS}"

T7_INIT=$(kubectl get pods -n "${NO_OPTIN_NS}" -l app=t7-no-optin -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null || true)
T7_CONT=$(kubectl get pods -n "${NO_OPTIN_NS}" -l app=t7-no-optin -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true)

assert_missing "Test 7" "${PROXY_INIT}"  "${T7_INIT}"
assert_missing "Test 7" "${ENVOY}"       "${T7_CONT}"
assert_missing "Test 7" "${SPIFFE}"      "${T7_CONT}"
assert_missing "Test 7" "${CLIENT_REG}"  "${T7_CONT}"

# ── Test 8: Decision Logs ────────────────────────────────────────────

separator
log "Test 8: Check injection decision logs"

DECISION_LOGS=$(kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager --tail=200 2>/dev/null | grep "injection decision" || true)

if [ -n "${DECISION_LOGS}" ]; then
  DECISION_COUNT=$(echo "${DECISION_LOGS}" | wc -l | tr -d ' ')
  pass "Test 8: Found ${DECISION_COUNT} injection decision log entries"
else
  fail "Test 8: No injection decision log entries found"
fi

# ── Cleanup ──────────────────────────────────────────────────────────

separator
log "Cleaning up..."

for dep in "${DEPLOYMENTS[@]}"; do
  kubectl delete deployment -n "${NS}" "${dep}" --ignore-not-found >/dev/null 2>&1
done
kubectl delete deployment -n "${NO_OPTIN_NS}" t7-no-optin --ignore-not-found >/dev/null 2>&1
kubectl delete namespace "${NO_OPTIN_NS}" --ignore-not-found >/dev/null 2>&1

reset_feature_gates
reset_kubelet

# ── Report ───────────────────────────────────────────────────────────

echo ""
separator
echo -e "${BOLD}  TEST REPORT${NC}"
separator
echo ""

for r in "${RESULTS[@]}"; do
  if [[ "${r}" == PASS* ]]; then
    echo -e "  ${GREEN}${r}${NC}"
  elif [[ "${r}" == FAIL* ]]; then
    echo -e "  ${RED}${r}${NC}"
  else
    echo -e "  ${YELLOW}${r}${NC}"
  fi
done

echo ""
separator
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${BOLD}Total: ${TOTAL}${NC}  ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}  ${YELLOW}Skipped: ${SKIP}${NC}"

if [ "${FAIL}" -gt 0 ]; then
  echo -e "  ${RED}${BOLD}SOME TESTS FAILED${NC}"
  separator
  echo ""
  exit 1
else
  echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  separator
  echo ""
  exit 0
fi
