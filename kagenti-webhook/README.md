# kagenti-webhook

A Kubernetes admission webhook that automatically injects sidecar containers to enable Keycloak client registration and optional SPIFFE/SPIRE token exchanges for secure service-to-service authentication within the Kagenti platform.

## Overview

This webhook provides security by automatically injecting sidecar containers that handle identity and authentication. It supports both standard Kubernetes workloads (Deployments, StatefulSets, etc.) and custom resources.

The webhook injects:

1. **`proxy-init`** (init container) - Configures iptables rules for traffic interception
2. **`envoy-proxy`** - Service mesh proxy for traffic management
3. **`spiffe-helper`** (optional, if SPIRE enabled) - Obtains SPIFFE Verifiable Identity Documents (SVIDs) from the SPIRE agent via the Workload API
4. **`kagenti-client-registration`** (optional, if SPIRE enabled) - Registers the resource as an OAuth2 client in Keycloak using the SPIFFE identity

### Why Sidecar Injection?

The sidecar approach provides a consistent pattern for extending functionality without modifying application code or upstream components.

## Supported Resources

The webhook supports sidecar injection for:

The **AuthBridge webhook** supports standard Kubernetes workload resources:

- **Deployments** (apps/v1)
- **StatefulSets** (apps/v1)
- **DaemonSets** (apps/v1)
- **Jobs** (batch/v1)
- **CronJobs** (batch/v1)

## Injection Control

The webhook supports flexible injection control via a multi-layer precedence system. Each sidecar's injection decision is evaluated independently through a chain of layers, where the first "no" short-circuits.

### Precedence Chain

For the AuthBridge webhook, each sidecar (`envoy-proxy`, `spiffe-helper`, `client-registration`) is evaluated through this chain:

```text
Global Feature Gate → Per-Sidecar Feature Gate → Namespace Label → Workload Label → TokenExchange CR → Platform Defaults → Inject
                                                                                     (spiffe-helper only: SPIRE opt-out label)
```

| Layer | Scope | How to configure | Effect |
| --- | --- | --- | --- |
| 1. Global Feature Gate | Cluster-wide | `featureGates.globalEnabled` in Helm values | Kill switch — disables ALL sidecar injection |
| 2. Per-Sidecar Feature Gate | Cluster-wide, per sidecar | `featureGates.envoyProxy`, `.spiffeHelper`, `.clientRegistration` in Helm values | Disables a specific sidecar cluster-wide |
| 3. Namespace Label | Namespace | `kagenti-enabled: "true"` label on namespace | Required — namespaces without this label receive no injection |
| 4. Workload Label | Per-workload, per sidecar | `kagenti.io/envoy-proxy-inject: "false"` (etc.) on pod template | Disables a specific sidecar for one workload |
| 5. TokenExchange CR | Per-workload | TokenExchange CR (stub — not yet implemented) | CR override takes precedence over platform defaults |
| 6. Platform Defaults | Cluster-wide, per sidecar | `defaults.sidecars.<sidecar>.enabled` in Helm values | Lowest-priority default; all sidecars enabled by default |
| 7. SPIRE opt-out *(spiffe-helper only)* | Per-workload | `kagenti.io/spire: "disabled"` on pod template | Blocks spiffe-helper injection for that workload |

All sidecars are injected **by default** when the namespace has `kagenti-enabled=true`. The `proxy-init` init container always follows the `envoy-proxy` decision (it is required for envoy to function).

### Feature Gates

Feature gates provide cluster-wide control over sidecar injection. They are configured via Helm values and deployed as a ConfigMap with hot-reload support.

```yaml
# values.yaml
featureGates:
  globalEnabled: true        # Kill switch — set to false to disable ALL injection
  envoyProxy: true           # Set to false to disable envoy-proxy cluster-wide
  spiffeHelper: true         # Set to false to disable spiffe-helper cluster-wide
  clientRegistration: true   # Set to false to disable client-registration cluster-wide
```

### Namespace-Level Injection

Enable injection for all eligible workloads in a namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-apps
  labels:
    kagenti-enabled: "true"  # All eligible workloads in this namespace get sidecars
```

### Workload-Level Control

Workloads must have the `kagenti.io/type` label set to `agent` or `tool` to be eligible for injection. Without this label, injection is always skipped.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-apps       # Namespace must have kagenti-enabled=true
spec:
  template:
    metadata:
      labels:
        app: my-app
        kagenti.io/type: agent        # Required: Identifies workload type (agent or tool)
        # kagenti.io/spire: disabled  # Optional: Add this label to opt out of spiffe-helper injection
    spec:
      containers:
      - name: app
        image: my-app:latest
```

### Per-Sidecar Workload Labels

Individual sidecars can be disabled per-workload using these labels on the pod template:

| Label | Controls |
| --- | --- |
| `kagenti.io/envoy-proxy-inject: "false"` | Disables envoy-proxy (and proxy-init) |
| `kagenti.io/spiffe-helper-inject: "false"` | Disables spiffe-helper |
| `kagenti.io/client-registration-inject: "false"` | Disables client-registration |

Example — disable envoy-proxy for a specific workload:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-envoy-app
  namespace: my-apps
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: agent
        kagenti.io/envoy-proxy-inject: "false"   # Skip envoy for this workload
    spec:
      containers:
      - name: app
        image: my-app:latest
```

### SPIRE Integration Opt-Out

`spiffe-helper` is injected by default when all precedence layers pass. To opt a specific workload out of SPIRE integration, set `kagenti.io/spire: disabled` on the pod template:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-no-spire
  namespace: my-apps
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: agent
        kagenti.io/spire: disabled  # Opt this workload out of spiffe-helper injection
    spec:
      containers:
      - name: app
        image: my-app:latest
```

Without this label (or with any value other than `disabled`), spiffe-helper is injected whenever the standard 6-layer precedence chain permits it.

### Platform Configuration

Container images, resource limits, proxy settings, and other parameters are externalized into a ConfigMap managed through Helm values. The webhook loads this configuration at startup and supports hot-reload via file watching.

```yaml
# values.yaml — defaults section
defaults:
  images:
    envoyProxy: ghcr.io/kagenti/kagenti-extensions/envoy-with-processor:latest
    proxyInit: ghcr.io/kagenti/kagenti-extensions/proxy-init:latest
    spiffeHelper: ghcr.io/spiffe/spiffe-helper:nightly
    clientRegistration: ghcr.io/kagenti/kagenti-extensions/client-registration:latest
    pullPolicy: IfNotPresent
  proxy:
    port: 15123
    uid: 1337
    adminPort: 9901
    inboundProxyPort: 15124
  resources:
    envoyProxy:
      requests: { cpu: 200m, memory: 256Mi }
      limits: { cpu: 50m, memory: 64Mi }
    # ... (proxyInit, spiffeHelper, clientRegistration)
  sidecars:
    envoyProxy: { enabled: true }
    spiffeHelper: { enabled: true }
    clientRegistration: { enabled: true }
```

If the ConfigMap is not available, compiled defaults are used as a fallback.

## Architecture

### AuthBridge Architecture

The AuthBridge webhook supports two modes of operation:

#### With SPIRE Integration (`kagenti.io/spire: enabled` label)

```
┌────────────────────────────────────────────────────────────────┐
│                    Kubernetes Workload Pod                     │
│                                                                │
│  ┌──────────────┐  ┌────────────┐  ┌─────────────────────────┐│
│  │  proxy-init  │  │ envoy-proxy│  │   spiffe-helper         ││
│  │ (init)       │  │            │  │                         ││
│  │ - Setup      │  │ - Service  │  │ 1. Connects to SPIRE    ││
│  │   iptables   │  │   mesh     │  │ 2. Gets JWT-SVID        ││
│  │ - Redirect   │  │   proxy    │  │ 3. Writes jwt_svid.token││
│  │   traffic    │  │            │  │                         ││
│  └──────────────┘  └────────────┘  └─────────────────────────┘│
│                                              │                 │
│                          ┌───────────────────▼──────────────┐  │
│  ┌─────────────────────┐ │    Shared Volume: /opt          │  │
│  │ client-registration │─│                                  │  │
│  │                     │ └──────────────────────────────────┘  │
│  │ 1. Waits for token  │                                       │
│  │ 2. Registers with   │                                       │
│  │    Keycloak         │                                       │
│  └─────────────────────┘                                       │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              Your Application Container                   │ │
│  │          (Deployment/StatefulSet/Job/etc.)               │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
  SPIRE Agent Socket   Keycloak Server      Application Traffic
                       (OAuth2/OIDC)        (via Envoy proxy)
```

#### Without SPIRE Integration (default, no `kagenti.io/spire` label)

```
┌────────────────────────────────────────────────────────────────┐
│                    Kubernetes Workload Pod                     │
│                                                                │
│  ┌──────────────┐  ┌────────────────────────────────────────┐ │
│  │  proxy-init  │  │           envoy-proxy                  │ │
│  │ (init)       │  │                                        │ │
│  │ - Setup      │  │ - Service mesh proxy                   │ │
│  │   iptables   │  │ - Traffic management                   │ │
│  │ - Redirect   │  │ - Authentication (non-SPIFFE methods)  │ │
│  │   traffic    │  │                                        │ │
│  └──────────────┘  └────────────────────────────────────────┘ │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              Your Application Container                   │ │
│  │          (Deployment/StatefulSet/Job/etc.)               │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                       Application Traffic
                        (via Envoy proxy)
```

For detailed architecture diagrams, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Features

### Automatic Container Injection

#### AuthBridge Containers

The AuthBridge webhook injects the following containers into Kubernetes workloads:

**Always injected:**

##### 1. Proxy Init (`proxy-init`) - Init Container

- **Image**: `ghcr.io/kagenti/kagenti-extensions/proxy-init:latest` (configurable)
- **Purpose**: Sets up iptables rules to redirect traffic through the Envoy proxy
- **Resources**: 10m CPU / 64Mi memory (request/limit)
- **Privileged**: Yes (required for iptables modification)

##### 2. Envoy Proxy (`envoy-proxy`) - Sidecar Container

- **Image**: `ghcr.io/kagenti/kagenti-extensions/envoy-with-processor:latest` (configurable)
- **Purpose**: Service mesh proxy for traffic management and authentication
- **Resources**: 50m CPU / 64Mi memory (request), 200m CPU / 256Mi memory (limit)
- **Ports**: 15123 (envoy-outbound), 9901 (admin), 9090 (ext-proc)

**Injected when `kagenti.io/spire: enabled` label is set:**

##### 3. SPIFFE Helper (`spiffe-helper`) - Sidecar Container

- **Image**: `ghcr.io/spiffe/spiffe-helper:nightly`
- **Purpose**: Obtains and refreshes JWT-SVIDs from SPIRE
- **Resources**: 50m CPU / 64Mi memory (request), 100m CPU / 128Mi memory (limit)
- **Volumes**:
  - `/spiffe-workload-api` - SPIRE agent socket
  - `/etc/spiffe-helper` - Configuration
  - `/opt` - SVID token output

##### 4. Client Registration (`kagenti-client-registration`) - Sidecar Container

- **Image**: `ghcr.io/kagenti/kagenti-extensions/client-registration:latest`
- **Purpose**: Registers resource as Keycloak OAuth2 client using SPIFFE identity
- **Resources**: 50m CPU / 64Mi memory (request), 100m CPU / 128Mi memory (limit)
- **Behavior**: Waits for `/opt/jwt_svid.token`, then registers with Keycloak
- **Volumes**:
  - `/opt` - Reads SVID token from spiffe-helper

### Automatic Volume Configuration

The webhook automatically adds these volumes:

- **`spire-agent-socket`** - CSI volume (`csi.spiffe.io` driver) providing the SPIRE Workload API socket for SPIRE agent access (when SPIRE enabled)
- **`spiffe-helper-config`** - ConfigMap containing SPIFFE helper configuration (when SPIRE enabled)
- **`svid-output`** - EmptyDir for SVID token exchange between sidecars (when SPIRE enabled)
- **`envoy-config`** - ConfigMap containing Envoy configuration


## Getting Started

### Prerequisites

- Kubernetes v1.11.3+ cluster
- Go v1.22+ (for development)
- Docker v17.03+ (for building images)
- kubectl v1.11.3+
- cert-manager v1.0+ (for webhook TLS certificates)
- SPIRE agent deployed on cluster nodes
- Keycloak server accessible from the cluster

### Quick Start with Helm

```bash

# Install the webhook using Helm
helm install kagenti-webhook oci://ghcr.io/kagenti/kagenti-extensions/kagenti-webhook-chart \
  --version <version> \
  --namespace kagenti-webhook-system \
  --create-namespace
```

### Local Development with Kind

```bash
cd kagenti-webhook

# Build and deploy to local Kind cluster in one command
make local-dev CLUSTER=<your-kind-cluster-name>

# Or step by step:
make ko-local-build                    # Build with ko
make kind-load-image CLUSTER=<name>    # Load into Kind
make install-local-chart CLUSTER=<name> # Deploy with Helm

# Reinstall after changes
make reinstall-local-chart CLUSTER=<name>
```

### Local Development with webhook-rollout.sh

When the webhook is deployed as a **subchart** (e.g., as part of a parent Helm chart), `helm upgrade` on the subchart alone can fail with an immutable `spec.selector` error because the parent chart may use different label selectors. The `webhook-rollout.sh` script works around this by using `kubectl set image` and `kubectl patch` instead of a full Helm upgrade.

The script handles the full build-and-deploy cycle:

1. Builds the Docker image locally
2. Loads the image into the Kind cluster
3. Deploys the platform defaults ConfigMap (`kagenti-webhook-defaults`)
4. Deploys the feature gates ConfigMap (`kagenti-webhook-feature-gates`)
5. Updates the deployment image and patches in config volume mounts
6. Creates the AuthBridge `MutatingWebhookConfiguration` if it doesn't exist

```bash
cd kagenti-webhook

# Basic usage (uses CLUSTER=kagenti by default)
./scripts/webhook-rollout.sh

# Specify cluster and container runtime
CLUSTER=my-cluster ./scripts/webhook-rollout.sh
DOCKER_IMPL=podman ./scripts/webhook-rollout.sh

# Include AuthBridge demo setup (namespace + ConfigMaps)
AUTHBRIDGE_DEMO=true ./scripts/webhook-rollout.sh
AUTHBRIDGE_DEMO=true AUTHBRIDGE_NAMESPACE=myns ./scripts/webhook-rollout.sh
```

Environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `CLUSTER` | `kagenti` | Kind cluster name |
| `NAMESPACE` | `kagenti-webhook-system` | Webhook deployment namespace |
| `DOCKER_IMPL` | auto-detected | Container runtime (`docker` or `podman`) |
| `AUTHBRIDGE_DEMO` | `false` | Set to `true` to create demo namespace + ConfigMaps |
| `AUTHBRIDGE_NAMESPACE` | `team1` | Namespace for AuthBridge demo workloads |

### Webhook Configuration

The webhook can be configured via Helm values or command-line flags:

```yaml
# values.yaml
webhook:
  enabled: true
  certPath: /tmp/k8s-webhook-server/serving-certs
  certName: tls.crt
  certKey: tls.key
  port: 9443
```


## Development

### Pod-Mutator Architecture

The webhook uses a shared pod mutation engine:

```bash
internal/webhook/
├── config/                          # Configuration layer
│   ├── types.go                     # PlatformConfig, SidecarDefaults types
│   ├── defaults.go                  # Compiled default values
│   ├── loader.go                    # ConfigMap-based config loader with hot-reload
│   ├── feature_gates.go             # FeatureGates type
│   └── feature_gate_loader.go       # Feature gates loader with hot-reload
├── injector/                        # Shared mutation logic
│   ├── pod_mutator.go               # Core mutation engine + InjectAuthBridge
│   ├── precedence.go                # Multi-layer precedence evaluator
│   ├── precedence_test.go           # Table-driven precedence tests
│   ├── injection_decision.go        # SidecarDecision, InjectionDecision types
│   ├── tokenexchange_overrides.go   # TokenExchange CR stub (future use)
│   ├── namespace_checker.go         # Namespace label inspection
│   ├── container_builder.go         # Build sidecars & init containers
│   └── volume_builder.go            # Build volumes
└── v1alpha1/
    └── authbridge_webhook.go        # AuthBridge webhook handler
```

The `InjectAuthBridge()` method supports:

- Init container injection (proxy-init)
- Sidecar container injection (envoy-proxy, spiffe-helper, client-registration)
- Optional SPIRE integration via pod labels
- Support for standard Kubernetes workloads (Deployments, StatefulSets, DaemonSets, Jobs, CronJobs)

## Uninstallation

### Using Helm

```bash
helm uninstall kagenti-webhook -n kagenti-webhook-system
```

## License

Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
