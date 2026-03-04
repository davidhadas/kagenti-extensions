#!/usr/bin/env bash
# test-precedence.sh — automated test runner for the multi-layer precedence system.
# Runs all tests sequentially and prints a report at the end.
#
# Usage:
#   ./scripts/test-precedence.sh [NAMESPACE]
#
# Default namespace: team1

set -euo pipefail

# ── Container runtime detection ───────────────────────────────────────
# Supports Docker and Podman. Override with DOCKER_IMPL=docker|podman.
detect_impl() {
  if [ -n "${DOCKER_IMPL-}" ]; then
    printf '%s\n' "${DOCKER_IMPL}"
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    out=$(podman info 2>/dev/null || true)
    if printf '%s' "$out" | grep -Ei 'apiversion|buildorigin|libpod|podman|version:' >/dev/null 2>&1; then
      printf 'podman\n'; return
    fi
  fi
  if command -v docker >/dev/null 2>&1; then
    out=$(docker info 2>/dev/null || true)
    if printf '%s' "$out" | grep -Ei 'client: docker engine|docker engine - community|server:' >/dev/null 2>&1; then
      printf 'docker\n'; return
    fi
    if printf '%s' "$out" | grep -Ei 'apiversion|buildorigin|libpod|podman|version:' >/dev/null 2>&1; then
      printf 'podman\n'; return
    fi
  fi
  printf 'unknown\n'
}

# ── Dependency checks ─────────────────────────────────────────────────
# Validate all required tools are present before touching the cluster.
check_deps() {
  local missing=()
  for cmd in kubectl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  # Require docker or podman
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    missing+=("docker or podman")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: Missing required tools: ${missing[*]}" >&2
    echo "Install them and re-run:" >&2
    echo "  kubectl — https://kubernetes.io/docs/tasks/tools/" >&2
    echo "  docker  — https://docs.docker.com/get-docker/" >&2
    echo "  podman  — https://podman.io/getting-started/installation" >&2
    echo "  jq      — https://stedolan.github.io/jq/download/" >&2
    exit 1
  fi
}
check_deps

CONTAINER_RT=$(detect_impl)
if [ "${CONTAINER_RT}" = "unknown" ]; then
  echo "ERROR: Could not detect a working Docker or Podman installation." >&2
  echo "Set DOCKER_IMPL=docker or DOCKER_IMPL=podman to override." >&2
  exit 1
fi

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
    | "${CONTAINER_RT}" exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
  "${CONTAINER_RT}" exec "${CLUSTER}-control-plane" systemctl restart kubelet

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
    | "${CONTAINER_RT}" exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
  "${CONTAINER_RT}" exec "${CLUSTER}-control-plane" systemctl restart kubelet

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

# Deploy a tool workload (kagenti.io/type=tool). Extra args are additional label lines.
deploy_tool() {
  local name=$1; shift
  local extra_labels=""
  for lbl in "$@"; do
    extra_labels="${extra_labels}
        ${lbl}"
  done

  kubectl delete deployment -n "${NS}" "${name}" --ignore-not-found >/dev/null 2>&1
  sleep 2

  kubectl apply -n "${NS}" -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    kagenti.io/type: tool
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
        kagenti.io/type: tool${extra_labels}
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
# Args: global envoy spiffe clientreg [tools=false]
set_feature_gates() {
  local global=$1 envoy=$2 spiffe=$3 clientreg=$4 tools=${5:-false}

  # Build the exact content this patch would store.
  local desired
  desired=$(printf 'globalEnabled: %s\nenvoyProxy: %s\nspiffeHelper: %s\nclientRegistration: %s\ninjectTools: %s\n' \
      "${global}" "${envoy}" "${spiffe}" "${clientreg}" "${tools}")

  # If the CM already holds the desired values, kubectl patch is a Kubernetes
  # no-op: the API server sees identical bytes, skips the etcd write, and
  # resourceVersion is not bumped.  The kubelet therefore never re-writes the
  # volume file, fsnotify never fires, and "Feature gates reloaded" is never
  # logged.  Skip the wait — the webhook is already using the correct values.
  local current
  current=$(kubectl get configmap "${FG_CM}" -n "${WEBHOOK_NS}" \
      -o go-template='{{index .data "feature-gates.yaml"}}' 2>/dev/null || true)
  if [[ "${current}" == "${desired}" ]]; then
    log "Feature gates already set: global=${global} envoy=${envoy} spiffe=${spiffe} clientreg=${clientreg} tools=${tools} (no change)"
    return
  fi

  # Record a timestamp BEFORE patching (RFC3339 UTC, required by kubectl --since-time).
  # This ensures we only match a "Feature gates reloaded" log entry that appeared
  # AFTER the ConfigMap patch — not a stale entry from a previous set_feature_gates call.
  local before_ts
  before_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  kubectl patch configmap "${FG_CM}" -n "${WEBHOOK_NS}" --type=merge \
    -p "{\"data\":{\"feature-gates.yaml\":\"globalEnabled: ${global}\nenvoyProxy: ${envoy}\nspiffeHelper: ${spiffe}\nclientRegistration: ${clientreg}\ninjectTools: ${tools}\n\"}}" >/dev/null
  log "Feature gates set: global=${global} envoy=${envoy} spiffe=${spiffe} clientreg=${clientreg} tools=${tools}"

  # Poll logs for "Feature gates reloaded successfully" (emitted by feature_gate_loader.go)
  # using --since-time to filter out reload messages from previous calls.
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

# Reset feature gates to defaults: all sidecars enabled, injectTools=false.
reset_feature_gates() {
  set_feature_gates true true true true false
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

# Speed up ConfigMap propagation first so that all subsequent hot-reload
# waits use the fast 10s kubelet sync (HOTRELOAD_MAX_WAIT=30s requires this).
# A brief pause lets the kubelet finish reinitializing after its restart.
speed_up_kubelet
# Ensure kubelet is always restored, even if set -e triggers an early exit.
trap reset_kubelet EXIT
sleep 10
log "Kubelet stabilized"

# Ensure feature gates are all enabled at start.
# Runs after speed_up_kubelet so the hot-reload confirmation arrives well
# within HOTRELOAD_MAX_WAIT.
reset_feature_gates

# Restart the webhook pod so startup banners appear at the top of the log.
# Runs after speed_up_kubelet so the new pod benefits from fast CM sync.
# Without this, a long-running pod may have thousands of log lines since
# startup, causing --tail=500 to miss the one-time banners.
log "Restarting webhook pod for fresh startup logs..."
kubectl rollout restart deployment/kagenti-webhook-controller-manager \
    -n "${WEBHOOK_NS}" >/dev/null
kubectl rollout status deployment/kagenti-webhook-controller-manager \
    -n "${WEBHOOK_NS}" --timeout=90s >/dev/null
log "Webhook pod ready"

# ── Test 1: Config Loading ───────────────────────────────────────────

separator
log "Test 1: Verify startup & config loading"

# The pod was just restarted above, so startup banners appear in the first
# few dozen lines. --tail=500 is sufficient and avoids clock-skew issues
# that make --since-time unreliable across local machine and cluster nodes.
CONFIG_LOGS=$(kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager \
    --tail=500 2>/dev/null || true)

if echo "${CONFIG_LOGS}" | grep -q "PLATFORM CONFIGURATION"; then
  pass "Test 1: Platform configuration banner found in logs"
elif echo "${CONFIG_LOGS}" | grep -q "Platform config"; then
  pass "Test 1: Platform config loaded (older log format)"
else
  fail "Test 1: Platform configuration NOT found in logs"
fi

if echo "${CONFIG_LOGS}" | grep -q "FEATURE GATES"; then
  pass "Test 1: Feature gates banner found in logs"
elif echo "${CONFIG_LOGS}" | grep -q "Feature gates\|feature.gate"; then
  pass "Test 1: Feature gates loaded (older log format)"
else
  fail "Test 1: Feature gates NOT found in logs"
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

set_feature_gates true false true true false
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

# ── Test 5: Whole-Workload Opt-Out ────────────────────────────────────

separator
log "Test 5: Whole-workload opt-out — kagenti.io/inject=disabled skips all sidecars (Stage 1)"

deploy t5-inject-disable 'kagenti.io/inject: "disabled"'

INIT=$(get_init_containers t5-inject-disable)
CONT=$(get_containers t5-inject-disable)

assert_missing "Test 5" "${PROXY_INIT}"  "${INIT}"
assert_missing "Test 5" "${ENVOY}"       "${CONT}"
assert_missing "Test 5" "${SPIFFE}"      "${CONT}"
assert_missing "Test 5" "${CLIENT_REG}"  "${CONT}"

# ── Test 6: Global Kill Switch ───────────────────────────────────────

separator
log "Test 6: Global kill switch OFF"

set_feature_gates false true true true false
deploy t6-global-off

INIT=$(get_init_containers t6-global-off)
CONT=$(get_containers t6-global-off)

assert_missing "Test 6" "${PROXY_INIT}"  "${INIT}"
assert_missing "Test 6" "${ENVOY}"       "${CONT}"
assert_missing "Test 6" "${SPIFFE}"      "${CONT}"
assert_missing "Test 6" "${CLIENT_REG}"  "${CONT}"

reset_feature_gates

# ── Test 7: Missing Type Label ────────────────────────────────────────

separator
log "Test 7: Stage 1 pre-filter — no kagenti.io/type label skips all sidecars"

# Deploy manually: deploy() always sets kagenti.io/type: agent, so we need a raw apply
kubectl delete deployment -n "${NS}" t7-no-type --ignore-not-found >/dev/null 2>&1
sleep 2
kubectl apply -n "${NS}" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t7-no-type
spec:
  replicas: 1
  selector:
    matchLabels:
      app: t7-no-type
  template:
    metadata:
      labels:
        app: t7-no-type
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF
DEPLOYMENTS+=("t7-no-type")
sleep "${WAIT_SECS}"

T7_INIT=$(get_init_containers t7-no-type)
T7_CONT=$(get_containers t7-no-type)

assert_missing "Test 7" "${PROXY_INIT}"  "${T7_INIT}"
assert_missing "Test 7" "${ENVOY}"       "${T7_CONT}"
assert_missing "Test 7" "${SPIFFE}"      "${T7_CONT}"
assert_missing "Test 7" "${CLIENT_REG}"  "${T7_CONT}"

# ── Test 8: Tool — injectTools=false (default, Stage 1 P3) ───────────

separator
log "Test 8: Stage 1 P3 — tool workload skipped when injectTools=false (default)"

# injectTools=false is the default; reset_feature_gates ensures it is set.
deploy_tool t8-tool-skip

T8_INIT=$(get_init_containers t8-tool-skip)
T8_CONT=$(get_containers t8-tool-skip)

assert_missing "Test 8" "${PROXY_INIT}"  "${T8_INIT}"
assert_missing "Test 8" "${ENVOY}"       "${T8_CONT}"
assert_missing "Test 8" "${SPIFFE}"      "${T8_CONT}"
assert_missing "Test 8" "${CLIENT_REG}"  "${T8_CONT}"

# ── Test 9: Tool — injectTools=true (Stage 1 P3) ─────────────────────

separator
log "Test 9: Stage 1 P3 — tool workload injected when injectTools=true"

set_feature_gates true true true true true
deploy_tool t9-tool-inject

T9_INIT=$(get_init_containers t9-tool-inject)
T9_CONT=$(get_containers t9-tool-inject)

assert_has     "Test 9" "${PROXY_INIT}"  "${T9_INIT}"
assert_has     "Test 9" "${ENVOY}"       "${T9_CONT}"
assert_has     "Test 9" "${SPIFFE}"      "${T9_CONT}"
assert_has     "Test 9" "${CLIENT_REG}"  "${T9_CONT}"

reset_feature_gates

# ── Test 10: spiffeHelper feature gate off (Stage 2 L1) ──────────────

separator
log "Test 10: Stage 2 L1 — spiffeHelper feature gate off"

set_feature_gates true true false true false
deploy t10-no-spiffe-gate

T10_INIT=$(get_init_containers t10-no-spiffe-gate)
T10_CONT=$(get_containers t10-no-spiffe-gate)

assert_has     "Test 10" "${PROXY_INIT}"  "${T10_INIT}"
assert_has     "Test 10" "${ENVOY}"       "${T10_CONT}"
assert_missing "Test 10" "${SPIFFE}"      "${T10_CONT}"
assert_has     "Test 10" "${CLIENT_REG}"  "${T10_CONT}"

reset_feature_gates

# ── Test 11: clientRegistration feature gate off (Stage 2 L1) ────────

separator
log "Test 11: Stage 2 L1 — clientRegistration feature gate off"

set_feature_gates true true true false false
deploy t11-no-clientreg-gate

T11_INIT=$(get_init_containers t11-no-clientreg-gate)
T11_CONT=$(get_containers t11-no-clientreg-gate)

assert_has     "Test 11" "${PROXY_INIT}"  "${T11_INIT}"
assert_has     "Test 11" "${ENVOY}"       "${T11_CONT}"
assert_has     "Test 11" "${SPIFFE}"      "${T11_CONT}"
assert_missing "Test 11" "${CLIENT_REG}"  "${T11_CONT}"

reset_feature_gates

# ── Test 12: envoy-proxy workload label opt-out (Stage 2 L2) ─────────

separator
log "Test 12: Stage 2 L2 — workload label opt-out: kagenti.io/envoy-proxy-inject=false"

deploy t12-no-envoy-label 'kagenti.io/envoy-proxy-inject: "false"'

T12_INIT=$(get_init_containers t12-no-envoy-label)
T12_CONT=$(get_containers t12-no-envoy-label)

# proxy-init mirrors envoy-proxy; both must be absent.
assert_missing "Test 12" "${PROXY_INIT}"  "${T12_INIT}"
assert_missing "Test 12" "${ENVOY}"       "${T12_CONT}"
assert_has     "Test 12" "${SPIFFE}"      "${T12_CONT}"
assert_has     "Test 12" "${CLIENT_REG}"  "${T12_CONT}"

# ── Test 13: client-registration workload label opt-out (Stage 2 L2) ─

separator
log "Test 13: Stage 2 L2 — workload label opt-out: kagenti.io/client-registration-inject=false"

deploy t13-no-clientreg-label 'kagenti.io/client-registration-inject: "false"'

T13_INIT=$(get_init_containers t13-no-clientreg-label)
T13_CONT=$(get_containers t13-no-clientreg-label)

assert_has     "Test 13" "${PROXY_INIT}"  "${T13_INIT}"
assert_has     "Test 13" "${ENVOY}"       "${T13_CONT}"
assert_has     "Test 13" "${SPIFFE}"      "${T13_CONT}"
assert_missing "Test 13" "${CLIENT_REG}"  "${T13_CONT}"

# ── Test 14: Decision Logs ────────────────────────────────────────────

separator
log "Test 14: Check injection decision logs"

DECISION_LOGS=$(kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager --tail=200 2>/dev/null | grep "injection decision" || true)

if [ -n "${DECISION_LOGS}" ]; then
  DECISION_COUNT=$(echo "${DECISION_LOGS}" | wc -l | tr -d ' ')
  pass "Test 14: Found ${DECISION_COUNT} injection decision log entries"
else
  fail "Test 14: No injection decision log entries found"
fi

# ── Cleanup ──────────────────────────────────────────────────────────

separator
log "Cleaning up..."

for dep in "${DEPLOYMENTS[@]}"; do
  kubectl delete deployment -n "${NS}" "${dep}" --ignore-not-found >/dev/null 2>&1
done

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
