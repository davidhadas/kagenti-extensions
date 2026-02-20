# Testing Plan: Multi-Layer Precedence System

## Prerequisites

```bash
# Deploy the new code
cd kagenti-webhook
AUTHBRIDGE_DEMO=true ./scripts/webhook-rollout.sh
```

## Test 1: Verify Startup & Config Loading

Check that feature gates and platform config are loaded:

```bash
kubectl logs -n kagenti-webhook-system -l control-plane=controller-manager --tail=50 | grep -E "Feature gates|Platform config|feature-gates"
```

You should see log lines confirming both configs loaded successfully.

## Test 2: Baseline — All Sidecars Injected (default)

With all gates enabled and namespace opted in, a workload with `kagenti.io/type=agent` should get all sidecars — including `spiffe-helper` — without any additional labels.

```bash
# Ensure namespace is opted in
kubectl label namespace team1 kagenti-enabled=true --overwrite

# Deploy a test workload — no SPIRE label needed; spiffe-helper is injected by default
kubectl apply -n team1 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-all-sidecars
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-all-sidecars
  template:
    metadata:
      labels:
        app: test-all-sidecars
        kagenti.io/type: agent
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF

# Wait and check — expect envoy-proxy, spiffe-helper, client-registration sidecars + proxy-init
sleep 10
kubectl get pods -n team1 -l app=test-all-sidecars -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}{end}'
```

**Expected**: `proxy-init` init container, plus `app`, `envoy-proxy`, `spiffe-helper`, `kagenti-client-registration` containers.

## Test 3: Per-Sidecar Feature Gate — Disable Envoy

Edit the feature gates ConfigMap to disable envoy:

```bash
kubectl edit configmap kagenti-webhook-feature-gates -n kagenti-webhook-system
# Change envoyProxy: true → envoyProxy: false
```

Wait ~10s for the hot-reload (check logs), then deploy a new test workload:

```bash
kubectl apply -n team1 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-envoy
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-no-envoy
  template:
    metadata:
      labels:
        app: test-no-envoy
        kagenti.io/type: agent
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF

sleep 10
kubectl get pods -n team1 -l app=test-no-envoy -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}{end}'
```

**Expected**: No `proxy-init`, no `envoy-proxy`. Should have `kagenti-client-registration` only (and `spiffe-helper` only if `kagenti.io/spire=enabled` label is present).

Restore the gate afterward:

```bash
kubectl edit configmap kagenti-webhook-feature-gates -n kagenti-webhook-system
# Change envoyProxy: false → envoyProxy: true
```

## Test 4: Workload Label Override — Disable Spiffe-Helper

Deploy with a per-sidecar opt-out label:

```bash
kubectl apply -n team1 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-spiffe
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-no-spiffe
  template:
    metadata:
      labels:
        app: test-no-spiffe
        kagenti.io/type: agent
        kagenti.io/spiffe-helper-inject: "false"
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF

sleep 10
kubectl get pods -n team1 -l app=test-no-spiffe -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}{end}'
```

**Expected**: Has `proxy-init`, `envoy-proxy`, `kagenti-client-registration` — but NO `spiffe-helper`.

## Test 5: Global Kill Switch

```bash
kubectl edit configmap kagenti-webhook-feature-gates -n kagenti-webhook-system
# Change globalEnabled: true → globalEnabled: false
```

Wait ~10s, then deploy:

```bash
kubectl apply -n team1 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-global-off
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-global-off
  template:
    metadata:
      labels:
        app: test-global-off
        kagenti.io/type: agent
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF

sleep 10
kubectl get pods -n team1 -l app=test-global-off -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}{end}'
```

**Expected**: Only `app` container. No sidecars, no init containers injected.

Restore afterward:

```bash
kubectl edit configmap kagenti-webhook-feature-gates -n kagenti-webhook-system
# Change globalEnabled: false → globalEnabled: true
```

## Test 6: Namespace Not Opted In

```bash
kubectl create namespace test-no-optin --dry-run=client -o yaml | kubectl apply -f -
# Do NOT label it with kagenti-enabled=true

kubectl apply -n test-no-optin -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-optin
  labels:
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-no-optin
  template:
    metadata:
      labels:
        app: test-no-optin
        kagenti.io/type: agent
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sleep", "3600"]
EOF

sleep 10
kubectl get pods -n test-no-optin -l app=test-no-optin -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}{end}'
```

**Expected**: Only `app`. No injection because the namespace webhook selector requires `kagenti-enabled=true`.

## Test 7: Check Decision Logs

For any test above, check the webhook logs for per-sidecar decision output:

```bash
kubectl logs -n kagenti-webhook-system -l control-plane=controller-manager --tail=100 | grep "injection decision"
```

You should see structured log lines like:

```text
INFO  pod-mutator  injection decision  {"sidecar": "envoy-proxy", "inject": true, "reason": "all gates passed", "layer": "default"}
INFO  pod-mutator  injection decision  {"sidecar": "proxy-init", "inject": true, "reason": "follows envoy-proxy decision", "layer": "default"}
INFO  pod-mutator  injection decision  {"sidecar": "spiffe-helper", "inject": false, "reason": "workload label disabled spiffe-helper", "layer": "workload-label"}
INFO  pod-mutator  injection decision  {"sidecar": "client-registration", "inject": true, "reason": "all gates passed", "layer": "default"}
```

## Cleanup

```bash
kubectl delete deployment -n team1 test-all-sidecars test-no-envoy test-no-spiffe test-global-off --ignore-not-found
kubectl delete deployment -n test-no-optin test-no-optin --ignore-not-found
kubectl delete namespace test-no-optin --ignore-not-found
```

## Summary Table

| Test | What it verifies | Expected outcome |
| --- | --- | --- |
| 1 | Config loading | Logs show feature gates + platform config loaded |
| 2 | Baseline injection | All 3 sidecars + proxy-init injected |
| 3 | Per-sidecar feature gate | envoy + proxy-init skipped, others injected |
| 4 | Workload label opt-out | spiffe-helper skipped, others injected |
| 5 | Global kill switch | All sidecars skipped |
| 6 | Namespace not opted in | No injection at all |
| 7 | Decision logging | Per-sidecar decisions visible in logs |
