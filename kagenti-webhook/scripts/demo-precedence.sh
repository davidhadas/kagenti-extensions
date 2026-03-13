#!/usr/bin/env bash
# demo-precedence.sh — Interactive tmux demo for the two-stage sidecar injection precedence.
#
# Demonstrates the full decision chain:
#
#   Stage 1 — PodMutator pre-filters (any "no" skips all injection):
#     Pre-filter 1: kagenti.io/type must be 'agent' or 'tool'
#     Pre-filter 2: featureGates.globalEnabled kill switch
#     Pre-filter 3: featureGates.injectTools required for tool workloads (default false)
#     Pre-filter 4: kagenti.io/inject=disabled whole-workload opt-out
#
#   Stage 2 — PrecedenceEvaluator, per-sidecar (independent for each sidecar):
#     Layer 1: Per-sidecar feature gate (featureGates.{envoyProxy,spiffeHelper,clientRegistration})
#     Layer 2: Workload opt-out label   (kagenti.io/<sidecar>-inject=false)
#
# tmux layout:
#   ┌──────────────────────────────────────────────────┐
#   │            Top: Scenario Runner                  │
#   ├────────────────────────┬─────────────────────────┤
#   │  Bottom-Left:          │  Bottom-Right:          │
#   │  kubectl get pods -w   │  Webhook controller     │
#   │  (live pod watch)      │  logs (injection decisions) │
#   └────────────────────────┴─────────────────────────┘
#
# Usage:
#   ./scripts/demo-precedence.sh              # launches tmux session
#   ./scripts/demo-precedence.sh --no-tmux    # runs without tmux (CI-friendly)

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────
DEMO_NS="demo-precedence"
WEBHOOK_NS="kagenti-webhook-system"
SESSION="demo-precedence"
CLUSTER="${CLUSTER:-kagenti}"
WAIT_SECS=12
FG_CM="kagenti-webhook-feature-gates"
# Kubelet default CM volume sync can take up to 2 min.
# Set FAST_KUBELET=true to pre-accelerate syncFrequency to 10s before the demo,
# which reduces HOTRELOAD_MAX_WAIT to 30s. Kubelet is reset at teardown.
FAST_KUBELET="${FAST_KUBELET:-false}"
# Default covers worst-case kubelet CM sync (~2 min). Use FAST_KUBELET=true to reduce to 30s.
HOTRELOAD_MAX_WAIT="${HOTRELOAD_MAX_WAIT:-150}"

# ── Container runtime detection ───────────────────────────────────────
# Required by speed_up_kubelet / reset_kubelet for docker/podman exec.
detect_impl() {
    if [ -n "${DOCKER_IMPL-}" ]; then printf '%s\n' "${DOCKER_IMPL}"; return; fi
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
CONTAINER_RT=$(detect_impl)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGMAPS_YAML="${SCRIPT_DIR}/../../AuthBridge/k8s/configmaps-webhook.yaml"

# Container names (must match Go constants in injector package)
ENVOY="envoy-proxy"
PROXY_INIT="proxy-init"
SPIFFE="spiffe-helper"
CLIENT_REG="kagenti-client-registration"

# ── Colours ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Result tracking ──────────────────────────────────────────────────
declare -a RESULT_NUMS=()
declare -a RESULT_TITLES=()
declare -a RESULT_STATUS=()

# ── Display helpers ──────────────────────────────────────────────────
banner() {
    local text="$1"
    local width=64
    local text_len=${#text}
    local pad=$(( (width - text_len) / 2 ))
    local pad_r=$(( width - pad - text_len ))
    printf "\n${CYAN}"
    printf '╔'; printf '═%.0s' $(seq 1 "$width"); printf '╗\n'
    printf '║'; printf ' %.0s' $(seq 1 "$pad"); printf "${BOLD}%s${NC}${CYAN}" "$text"; printf ' %.0s' $(seq 1 "$pad_r"); printf '║\n'
    printf '╚'; printf '═%.0s' $(seq 1 "$width"); printf '╝\n'
    printf "${NC}\n"
}

scenario_banner() {
    local num="$1" title="$2" desc="$3"
    printf "\n${YELLOW}"
    printf '━%.0s' $(seq 1 64)
    printf "${NC}\n"
    printf "  ${BOLD}Scenario %s: %s${NC}\n" "$num" "$title"
    printf "  ${DIM}%s${NC}\n" "$desc"
    printf "${YELLOW}"
    printf '━%.0s' $(seq 1 64)
    printf "${NC}\n\n"
}

pass()   { printf "  ${GREEN}✔ PASS${NC}: %s\n" "$1"; }
fail()   { printf "  ${RED}✘ FAIL${NC}: %s\n" "$1"; }
info()   { printf "  ${CYAN}ℹ${NC}  %s\n" "$1"; }
detail() { printf "     ${DIM}%s${NC}\n" "$1"; }

# ── Kubernetes helpers ───────────────────────────────────────────────

# Deploy a test workload. $1=name, remaining args are extra label lines
# (pre-indented, e.g. 'kagenti.io/spiffe-helper-inject: "false"').
deploy() {
    local name=$1; shift
    local extra_labels=""
    for lbl in "$@"; do
        extra_labels="${extra_labels}
        ${lbl}"
    done

    # Delete first to ensure a clean CREATE (not UPDATE) so the webhook fires
    kubectl delete deployment -n "${DEMO_NS}" "${name}" --ignore-not-found >/dev/null 2>&1
    sleep 2

    info "Deploying ${name}..."
    kubectl apply -n "${DEMO_NS}" -f - <<EOF >/dev/null
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
        image: busybox:1.36
        command: ["sleep", "3600"]
EOF
    sleep "${WAIT_SECS}"
}

# Deploy a workload WITHOUT kagenti.io/type label (for pre-filter test).
deploy_no_type() {
    local name=$1

    kubectl delete deployment -n "${DEMO_NS}" "${name}" --ignore-not-found >/dev/null 2>&1
    sleep 2

    info "Deploying ${name} (no kagenti.io/type label)..."
    kubectl apply -n "${DEMO_NS}" -f - <<INNEREOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sleep", "3600"]
INNEREOF
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

    kubectl delete deployment -n "${DEMO_NS}" "${name}" --ignore-not-found >/dev/null 2>&1
    sleep 2

    info "Deploying ${name} (type=tool)..."
    kubectl apply -n "${DEMO_NS}" -f - <<EOF >/dev/null
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
        image: busybox:1.36
        command: ["sleep", "3600"]
EOF
    sleep "${WAIT_SECS}"
}

# Return space-separated list of container names for a pod.
get_containers() {
    kubectl get pods -n "${DEMO_NS}" -l "app=$1" \
        -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true
}

# Return space-separated list of init container names for a pod.
get_init_containers() {
    kubectl get pods -n "${DEMO_NS}" -l "app=$1" \
        -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null || true
}

# Check if a name exists in a space-separated list.
has() {
    local needle=$1 haystack=$2
    [[ " ${haystack} " == *" ${needle} "* ]]
}

# Cleanup a single deployment and wait briefly for pods to vanish.
cleanup_deploy() {
    local name="$1"
    kubectl delete deployment -n "${DEMO_NS}" "${name}" --ignore-not-found \
        --grace-period=0 --force >/dev/null 2>&1 || true
    local elapsed=0
    while (( elapsed < 10 )); do
        if ! kubectl get pods -n "${DEMO_NS}" -l "app=${name}" 2>/dev/null | grep -q "${name}"; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# ── Feature gate management ──────────────────────────────────────────

# Patch the feature-gates ConfigMap and wait for the webhook to confirm hot-reload.
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
        info "Feature gates → global=${global} envoy=${envoy} spiffe=${spiffe} clientreg=${clientreg} tools=${tools} (no change)"
        return
    fi

    # Record timestamp BEFORE patching so --since-time only matches new entries.
    local before_ts
    before_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    kubectl patch configmap "${FG_CM}" -n "${WEBHOOK_NS}" --type=merge \
        -p "{\"data\":{\"feature-gates.yaml\":\"globalEnabled: ${global}\nenvoyProxy: ${envoy}\nspiffeHelper: ${spiffe}\nclientRegistration: ${clientreg}\ninjectTools: ${tools}\n\"}}" >/dev/null
    info "Feature gates → global=${global} envoy=${envoy} spiffe=${spiffe} clientreg=${clientreg} tools=${tools}"
    info "Waiting for hot-reload (up to ${HOTRELOAD_MAX_WAIT}s)..."

    local waited=0
    while (( waited < HOTRELOAD_MAX_WAIT )); do
        if kubectl logs -n "${WEBHOOK_NS}" -l control-plane=controller-manager \
                --since-time="${before_ts}" 2>/dev/null \
                | grep -q "Feature gates reloaded"; then
            info "Hot-reload confirmed (${waited}s)"
            sleep 2
            return
        fi
        sleep 5
        waited=$((waited + 5))
        printf "\r  ... %ds elapsed" "${waited}"
    done
    printf "\n"
    info "WARNING: Hot-reload not confirmed after ${HOTRELOAD_MAX_WAIT}s — proceeding anyway"
}

reset_feature_gates() {
    set_feature_gates true true true true false
}

# ── Assertion helpers ────────────────────────────────────────────────

# $1=scenario title, $2=sidecar name, $3=container list, $4=expect "present"|"absent"
check_sidecar() {
    local title="$1" sidecar="$2" list="$3" expect="$4"
    if [[ "$expect" == "present" ]]; then
        if has "$sidecar" "$list"; then
            detail "${sidecar}: present ✓"
            return 0
        else
            detail "${sidecar}: MISSING (expected present)"
            return 1
        fi
    else
        if has "$sidecar" "$list"; then
            detail "${sidecar}: PRESENT (expected absent)"
            return 1
        else
            detail "${sidecar}: absent ✓"
            return 0
        fi
    fi
}

# ── Kubelet speedup (FAST_KUBELET=true) ──────────────────────────────

# Patch kubelet-config ConfigMap to set syncFrequency=10s and restart kubelet.
# This makes ConfigMap volume propagation near-instant (~10s) instead of the
# default (up to 2 minutes), allowing HOTRELOAD_MAX_WAIT to be set to 30s.
speed_up_kubelet() {
    info "Setting kubelet syncFrequency=10s (FAST_KUBELET=true)..."
    kubectl get configmap kubelet-config -n kube-system -o json \
        | jq '.data.kubelet |= (split("\n")
            | map(select(startswith("syncFrequency:") | not))
            + ["syncFrequency: 10s"]
            | join("\n"))' \
        | kubectl apply -f - >/dev/null
    kubectl get configmap kubelet-config -n kube-system \
        -o jsonpath='{.data.kubelet}' \
        | "${CONTAINER_RT}" exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
    "${CONTAINER_RT}" exec "${CLUSTER}-control-plane" systemctl restart kubelet
    sleep 5
    info "Kubelet restarted with syncFrequency=10s"
}

# Remove syncFrequency override and restore default kubelet behaviour.
reset_kubelet() {
    info "Resetting kubelet syncFrequency to default..."
    kubectl get configmap kubelet-config -n kube-system -o json \
        | jq '.data.kubelet |= (split("\n")
            | map(select(startswith("syncFrequency:") | not))
            | join("\n"))' \
        | kubectl apply -f - >/dev/null
    kubectl get configmap kubelet-config -n kube-system \
        -o jsonpath='{.data.kubelet}' \
        | "${CONTAINER_RT}" exec -i "${CLUSTER}-control-plane" tee /var/lib/kubelet/config.yaml >/dev/null
    "${CONTAINER_RT}" exec "${CLUSTER}-control-plane" systemctl restart kubelet
    sleep 5
    info "Kubelet reset to default syncFrequency"
}

# ── Setup / Teardown ─────────────────────────────────────────────────
setup() {
    banner "Multi-Layer Injection Precedence Demo"

    if [[ "${FAST_KUBELET}" == "true" ]]; then
        speed_up_kubelet
        sleep 10
        info "Kubelet stabilized — ConfigMap propagation is now ~10s"
        HOTRELOAD_MAX_WAIT=30
        # Restart the webhook pod so the new pod picks up the fast CM sync
        # from the start (same pattern as test-precedence.sh).  Without this,
        # the running pod's volume mount still uses the old slow sync interval.
        info "Restarting webhook pod to pick up fast CM sync..."
        kubectl rollout restart deployment/kagenti-webhook-controller-manager \
            -n "${WEBHOOK_NS}" >/dev/null
        kubectl rollout status deployment/kagenti-webhook-controller-manager \
            -n "${WEBHOOK_NS}" --timeout=90s >/dev/null
        info "Webhook pod ready — hot-reload window is now ${HOTRELOAD_MAX_WAIT}s"
    fi

    info "Creating namespace ${DEMO_NS}..."
    kubectl create namespace "${DEMO_NS}" --dry-run=client -o yaml | kubectl apply -f -

    info "Applying required ConfigMaps to ${DEMO_NS}..."
    if [[ -f "$CONFIGMAPS_YAML" ]]; then
        sed "s/namespace: team1/namespace: ${DEMO_NS}/g" "$CONFIGMAPS_YAML" \
            | kubectl apply -f -
    else
        info "ConfigMaps YAML not found at ${CONFIGMAPS_YAML}"
        info "Copying ConfigMaps from team1 namespace instead..."
        for cm in authbridge-config spiffe-helper-config envoy-config; do
            kubectl get configmap "$cm" -n team1 -o yaml 2>/dev/null \
                | sed "s/namespace: team1/namespace: ${DEMO_NS}/g" \
                | kubectl apply -f - 2>/dev/null \
                || info "  ConfigMap ${cm} not found in team1, skipping"
        done
    fi

    if [[ "${FAST_KUBELET}" != "true" ]]; then
        printf "\n"
        info "TIP: Re-run with FAST_KUBELET=true to reduce hot-reload waits from ~150s to ~30s."
        info "     Requires kind cluster access (docker/podman exec on control-plane node)."
        printf "\n"
    fi

    info "Ensuring feature gates are at defaults before starting..."
    reset_feature_gates

    printf "\n"
    info "Injection decision chain:"
    info "  Stage 1 — pre-filters (all-or-nothing):"
    info "    P1: kagenti.io/type must be 'agent' or 'tool'"
    info "    P2: featureGates.globalEnabled kill switch"
    info "    P3: featureGates.injectTools gate (tools default to no injection)"
    info "    P4: kagenti.io/inject=disabled  whole-workload opt-out"
    info ""
    info "  Stage 2 — per-sidecar (independent for each sidecar):"
    info "    L1: featureGates.{envoyProxy,spiffeHelper,clientRegistration}"
    info "    L2: kagenti.io/<sidecar>-inject=false  workload opt-out label"
    printf "\n"
    info "10 scenarios will be run. Press Enter to advance between them."
    printf "\n"
}

teardown() {
    banner "Cleaning Up"
    info "Resetting feature gates to defaults..."
    reset_feature_gates
    if [[ "${FAST_KUBELET}" == "true" ]]; then
        reset_kubelet
    fi
    info "Deleting namespace ${DEMO_NS}..."
    kubectl delete namespace "${DEMO_NS}" --ignore-not-found --wait=false
    info "Done. Namespace will be garbage-collected in the background."
}

print_summary() {
    printf "\n"
    banner "Results Summary"
    printf "  ${BOLD}%-4s %-46s %-8s${NC}\n" "#" "Scenario" "Result"
    printf "  %-4s %-46s %-8s\n" "----" "----------------------------------------------" "--------"
    local pass_count=0 fail_count=0
    for i in "${!RESULT_NUMS[@]}"; do
        local num="${RESULT_NUMS[$i]}"
        local title="${RESULT_TITLES[$i]}"
        local status="${RESULT_STATUS[$i]}"
        if [[ "$status" == "PASS" ]]; then
            printf "  %-4s %-46s ${GREEN}%-8s${NC}\n" "$num" "$title" "$status"
            pass_count=$((pass_count + 1))
        else
            printf "  %-4s %-46s ${RED}%-8s${NC}\n" "$num" "$title" "$status"
            fail_count=$((fail_count + 1))
        fi
    done
    printf "\n"
    local total=$((pass_count + fail_count))
    printf "  ${BOLD}Total: %d${NC}  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}\n\n" \
        "$total" "$pass_count" "$fail_count"
}

# ── Scenario runner ──────────────────────────────────────────────────

run_scenario() {
    local num="$1" title="$2" desc="$3"
    local deploy_name="demo-s${num}"

    scenario_banner "$num" "$title" "$desc"

    # The rest of the logic is scenario-specific — handled in run_scenarios
}

run_scenarios() {
    # Ensure teardown always runs on Ctrl+C, set -e failure, or any other exit.
    # Disarmed before the explicit teardown call at the end to avoid running twice.
    trap 'teardown 2>/dev/null || true' EXIT

    setup
    read -rp "  Press Enter to start scenarios..."

    # ─── Scenario 1: Happy path — all sidecars injected ──────────────
    local S=1 T="Default — all sidecars injected"
    scenario_banner $S "$T" \
        "kagenti.io/type=agent, no opt-out labels → all layers pass, full injection"

    deploy "demo-s1"

    local CONT INIT ok=true
    CONT=$(get_containers demo-s1)
    INIT=$(get_init_containers demo-s1)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    check_sidecar "$T" "$ENVOY"      "$CONT" present   || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" present   || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" present   || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s1

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 2: Global kill switch ─────────────────────────────
    S=2; T="Global kill switch — featureGates.globalEnabled=false"
    scenario_banner $S "$T" \
        "globalEnabled=false → Stage 1 P2 blocks all injection cluster-wide; no sidecars for any workload"

    set_feature_gates false true true true false
    deploy "demo-s2"

    CONT=$(get_containers demo-s2)
    INIT=$(get_init_containers demo-s2)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" absent    || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s2
    reset_feature_gates

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 3: Tool workload — injectTools=false (default) ─────
    S=3; T="Tool workload — injectTools=false (default, skipped)"
    scenario_banner $S "$T" \
        "kagenti.io/type=tool + featureGates.injectTools=false (default) → Stage 1 P3 blocks injection"

    info "featureGates.injectTools defaults to false — no patch needed."
    deploy_tool "demo-s3"

    CONT=$(get_containers demo-s3)
    INIT=$(get_init_containers demo-s3)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" absent    || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s3

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 4: Tool workload — injectTools=true ────────────────
    S=4; T="Tool workload — injectTools=true (injection enabled)"
    scenario_banner $S "$T" \
        "kagenti.io/type=tool + featureGates.injectTools=true → Stage 1 P3 passes; all sidecars injected"

    set_feature_gates true true true true true
    deploy_tool "demo-s4"

    CONT=$(get_containers demo-s4)
    INIT=$(get_init_containers demo-s4)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" present   || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" present   || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" present   || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s4
    reset_feature_gates

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 5: Missing type label — Stage 1 P1 ────────────────
    S=5; T="Missing type label — pre-filter skip"
    scenario_banner $S "$T" \
        "No kagenti.io/type label → Stage 1 P1 rejects workload before any other check runs"

    deploy_no_type "demo-s5"

    CONT=$(get_containers demo-s5)
    INIT=$(get_init_containers demo-s5)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" absent    || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s5

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 6: Whole-workload opt-out — Stage 1 P4 ─────────────
    S=6; T="Whole-workload opt-out (kagenti.io/inject=disabled)"
    scenario_banner $S "$T" \
        "kagenti.io/inject=disabled → Stage 1 P4 short-circuits before Stage 2; no sidecars injected"

    deploy "demo-s6" 'kagenti.io/inject: "disabled"'

    CONT=$(get_containers demo-s6)
    INIT=$(get_init_containers demo-s6)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" absent    || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s6

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 7: Per-sidecar feature gate — Stage 2 L1 ───────────
    S=7; T="Per-sidecar feature gate — spiffeHelper=false"
    scenario_banner $S "$T" \
        "featureGates.spiffeHelper=false → Stage 2 L1 blocks spiffe-helper cluster-wide; envoy + client-reg unaffected"

    set_feature_gates true true false true false
    deploy "demo-s7"

    CONT=$(get_containers demo-s7)
    INIT=$(get_init_containers demo-s7)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" present   || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" present   || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s7
    reset_feature_gates

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 8: spiffe-helper opt-out — Stage 2 L2 ─────────────
    S=8; T="spiffe-helper opt-out (workload label)"
    scenario_banner $S "$T" \
        "kagenti.io/spiffe-helper-inject=false → Stage 2 L2 blocks spiffe-helper; envoy + client-reg unaffected"

    deploy "demo-s8" 'kagenti.io/spiffe-helper-inject: "false"'

    CONT=$(get_containers demo-s8)
    INIT=$(get_init_containers demo-s8)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" present   || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" present   || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s8

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 9: envoy-proxy opt-out — Stage 2 L2 ────────────────
    S=9; T="envoy-proxy opt-out (workload label)"
    scenario_banner $S "$T" \
        "kagenti.io/envoy-proxy-inject=false → Stage 2 L2 blocks envoy + proxy-init; other sidecars unaffected"

    deploy "demo-s9" 'kagenti.io/envoy-proxy-inject: "false"'

    CONT=$(get_containers demo-s9)
    INIT=$(get_init_containers demo-s9)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" present   || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s9

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 10: Combo — no envoy + no spiffe-helper ────────────
    S=10; T="Combo: no envoy + no spiffe-helper"
    scenario_banner $S "$T" \
        "envoy-proxy-inject=false + spiffe-helper-inject=false → only client-registration injected"

    deploy "demo-s10" \
        'kagenti.io/envoy-proxy-inject: "false"' \
        'kagenti.io/spiffe-helper-inject: "false"'

    CONT=$(get_containers demo-s10)
    INIT=$(get_init_containers demo-s10)
    info "Containers:      ${CONT}"
    info "Init containers: ${INIT}"
    printf "\n"

    ok=true
    check_sidecar "$T" "$ENVOY"      "$CONT" absent    || ok=false
    check_sidecar "$T" "$SPIFFE"     "$CONT" absent    || ok=false
    check_sidecar "$T" "$CLIENT_REG" "$CONT" present   || ok=false
    check_sidecar "$T" "$PROXY_INIT" "$INIT" absent    || ok=false
    printf "\n"

    if $ok; then pass "$T"; else fail "$T"; fi
    RESULT_NUMS+=($S); RESULT_TITLES+=("$T"); RESULT_STATUS+=("$( $ok && echo PASS || echo FAIL )")
    cleanup_deploy demo-s10

    # ─── Summary ─────────────────────────────────────────────────────
    print_summary

    read -rp "  Press Enter to clean up and exit..."
    trap - EXIT  # disarm — about to call teardown explicitly
    teardown
}

# ── tmux orchestration ───────────────────────────────────────────────
launch_tmux() {
    if ! command -v tmux &>/dev/null; then
        echo "tmux not found — running without split panes."
        run_scenarios
        return
    fi

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Kill leftover session from a previous run
    tmux kill-session -t "${SESSION}" 2>/dev/null || true

    # Top pane: scenario runner
    tmux new-session -d -s "${SESSION}" -x 200 -y 50 \
        "bash '${script_path}' --run; echo ''; echo 'Demo complete. Press Enter to close.'; read; exit"

    # Bottom-left pane: live pod watch
    tmux split-window -t "${SESSION}:0" -v -l 14 \
        "while ! kubectl get ns ${DEMO_NS} &>/dev/null; do printf '\\rWaiting for namespace ${DEMO_NS}...'; sleep 2; done; echo ''; kubectl get pods -n ${DEMO_NS} -w"

    # Bottom-right pane: webhook controller logs (filtered to injection decisions)
    tmux split-window -t "${SESSION}:0.1" -h -l '50%' \
        "kubectl logs -n ${WEBHOOK_NS} -l control-plane=controller-manager -f --tail=50 2>/dev/null || echo 'Could not stream webhook logs. Is the controller running in ${WEBHOOK_NS}?'"

    # Select the top pane so the presenter types there
    tmux select-pane -t "${SESSION}:0.0"

    # Pane border titles (tmux ≥ 2.6)
    tmux select-pane -t "${SESSION}:0.0" -T "Scenario Runner" 2>/dev/null || true
    tmux select-pane -t "${SESSION}:0.1" -T "Pod Watch (${DEMO_NS})" 2>/dev/null || true
    tmux select-pane -t "${SESSION}:0.2" -T "Webhook Logs (${WEBHOOK_NS})" 2>/dev/null || true
    tmux set-option -t "${SESSION}" pane-border-status top 2>/dev/null || true

    tmux attach -t "${SESSION}"
}

# ── Entry point ──────────────────────────────────────────────────────
case "${1:-}" in
    --run)
        run_scenarios
        ;;
    --no-tmux)
        run_scenarios
        ;;
    *)
        launch_tmux
        ;;
esac
