#!/usr/bin/env bash
# demo-precedence.sh — Interactive tmux demo for the multi-layer sidecar injection precedence.
#
# Demonstrates the full decision chain:
#   Tier 0 (K8s API):     namespaceSelector requires kagenti-enabled=true for webhook to fire
#   Pre-filter:           Workload must have kagenti.io/type=agent (or tool)
#   Layer 1:              Global feature gate (kill switch)
#   Layer 2:              Per-sidecar feature gate
#   Layer 3:              Namespace label (kagenti-enabled=true)
#   Layer 4:              Workload per-sidecar labels (kagenti.io/<sidecar>-inject=false)
#   Layer 5:              TokenExchange CR override (stub — not yet wired)
#   Layer 6:              Platform defaults
#   Layer 7:              SPIRE label (spiffe-helper only, kagenti.io/spire=disabled)
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
WAIT_SECS=12

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
# (pre-indented, e.g. 'kagenti.io/spire: "disabled"').
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
    kubectl apply -n "${DEMO_NS}" -f - <<'INNEREOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: DEPLOY_NAME_PLACEHOLDER
spec:
  replicas: 1
  selector:
    matchLabels:
      app: DEPLOY_NAME_PLACEHOLDER
  template:
    metadata:
      labels:
        app: DEPLOY_NAME_PLACEHOLDER
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sleep", "3600"]
INNEREOF
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

# ── Setup / Teardown ─────────────────────────────────────────────────
setup() {
    banner "Multi-Layer Injection Precedence Demo"

    info "Creating namespace ${DEMO_NS}..."
    kubectl create namespace "${DEMO_NS}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${DEMO_NS}" kagenti-enabled=true --overwrite

    info "Applying required ConfigMaps to ${DEMO_NS}..."
    if [[ -f "$CONFIGMAPS_YAML" ]]; then
        sed "s/namespace: team1/namespace: ${DEMO_NS}/g" "$CONFIGMAPS_YAML" \
            | kubectl apply -f -
    else
        info "ConfigMaps YAML not found at ${CONFIGMAPS_YAML}"
        info "Copying ConfigMaps from team1 namespace instead..."
        for cm in environments authbridge-config spiffe-helper-config envoy-config; do
            kubectl get configmap "$cm" -n team1 -o yaml 2>/dev/null \
                | sed "s/namespace: team1/namespace: ${DEMO_NS}/g" \
                | kubectl apply -f - 2>/dev/null \
                || info "  ConfigMap ${cm} not found in team1, skipping"
        done
    fi

    printf "\n"
    info "Precedence chain (highest → lowest priority):"
    info "  Tier 0  K8s API:          namespaceSelector requires kagenti-enabled=true"
    info "  Pre:    Type filter:      kagenti.io/type must be 'agent' or 'tool'"
    info "  L1:     Global gate:      feature-gates.globalEnabled"
    info "  L2:     Per-sidecar gate: feature-gates.{envoyProxy,spiffeHelper,clientRegistration}"
    info "  L3:     Namespace label:  kagenti-enabled=true"
    info "  L4:     Workload label:   kagenti.io/<sidecar>-inject=false  (opt-out)"
    info "  L5:     CR override:      TokenExchange CR (stub, not yet wired)"
    info "  L6:     Platform default:  sidecars.<sidecar>.enabled"
    info "  L7:     SPIRE label:      kagenti.io/spire=disabled  (spiffe-helper only)"
    printf "\n"
    info "6 scenarios will be run. Press Enter to advance between them."
    printf "\n"
}

teardown() {
    banner "Cleaning Up"
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
    setup
    read -rp "  Press Enter to start scenarios..."

    # ─── Scenario 1: Default — all sidecars injected ─────────────────
    local S=1 T="Default — all sidecars injected"
    scenario_banner $S "$T" \
        "NS kagenti-enabled=true + kagenti.io/type=agent → all layers pass, full injection"

    info "Namespace label: kagenti-enabled=true (already set)"
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

    # ─── Scenario 2: SPIRE opt-out ──────────────────────────────────
    S=2; T="SPIRE opt-out (no spiffe-helper)"
    scenario_banner $S "$T" \
        "kagenti.io/spire=disabled → Layer 7 blocks spiffe-helper; other sidecars unaffected"

    info "Namespace label: kagenti-enabled=true"
    deploy "demo-s2" 'kagenti.io/spire: "disabled"'

    CONT=$(get_containers demo-s2)
    INIT=$(get_init_containers demo-s2)
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
    cleanup_deploy demo-s2

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 3: Per-sidecar opt-out (envoy-proxy) ──────────────
    S=3; T="Per-sidecar opt-out (no envoy-proxy)"
    scenario_banner $S "$T" \
        "kagenti.io/envoy-proxy-inject=false → Layer 4 blocks envoy + proxy-init"

    info "Namespace label: kagenti-enabled=true"
    deploy "demo-s3" 'kagenti.io/envoy-proxy-inject: "false"'

    CONT=$(get_containers demo-s3)
    INIT=$(get_init_containers demo-s3)
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
    cleanup_deploy demo-s3

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 4: Namespace hard gate ─────────────────────────────
    S=4; T="Namespace disabled — hard gate"
    scenario_banner $S "$T" \
        "Remove kagenti-enabled label → webhook NEVER fires, no injection regardless of workload labels"

    info "Removing namespace label: kagenti-enabled"
    kubectl label namespace "${DEMO_NS}" kagenti-enabled- 2>/dev/null || true
    deploy "demo-s4"

    CONT=$(get_containers demo-s4)
    INIT=$(get_init_containers demo-s4)
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
    cleanup_deploy demo-s4

    # Restore namespace label for remaining scenarios
    kubectl label namespace "${DEMO_NS}" kagenti-enabled=true --overwrite >/dev/null

    read -rp "  Press Enter for next scenario..."

    # ─── Scenario 5: Missing type label (pre-filter) ────────────────
    S=5; T="Missing type label — pre-filter skip"
    scenario_banner $S "$T" \
        "No kagenti.io/type label → pre-filter rejects workload before precedence chain runs"

    info "Namespace label: kagenti-enabled=true (restored)"

    # Special deployment without kagenti.io/type
    local deploy_name="demo-s5"
    kubectl delete deployment -n "${DEMO_NS}" "${deploy_name}" --ignore-not-found >/dev/null 2>&1
    sleep 2
    info "Deploying ${deploy_name} (no kagenti.io/type label)..."
    kubectl apply -n "${DEMO_NS}" -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${deploy_name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${deploy_name}
  template:
    metadata:
      labels:
        app: ${deploy_name}
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sleep", "3600"]
EOF
    sleep "${WAIT_SECS}"

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

    # ─── Scenario 6: Combo — no envoy + no spiffe ───────────────────
    S=6; T="Combo: no envoy + no spiffe-helper"
    scenario_banner $S "$T" \
        "envoy-proxy-inject=false (L4) + spire=disabled (L7) → only client-registration injected"

    info "Namespace label: kagenti-enabled=true"
    deploy "demo-s6" \
        'kagenti.io/envoy-proxy-inject: "false"' \
        'kagenti.io/spire: "disabled"'

    CONT=$(get_containers demo-s6)
    INIT=$(get_init_containers demo-s6)
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
    cleanup_deploy demo-s6

    # ─── Summary ─────────────────────────────────────────────────────
    print_summary

    read -rp "  Press Enter to clean up and exit..."
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
