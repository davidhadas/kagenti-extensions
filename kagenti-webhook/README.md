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

The webhook supports flexible injection control via namespace labels and pod labels/annotations, similar to Istio's sidecar injection pattern.

### Namespace-Level Injection

Enable injection for all workloads in a namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-apps
  labels:
    kagenti-enabled: "true"  # All workloads in this namespace get sidecars
```

Now all Deployments, StatefulSets, Jobs, etc. created in the `my-apps` namespace automatically get sidecars:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-apps
spec:
  template:
    metadata:
      labels:
        app: my-app
        kagenti.io/type: agent        # Required: Identifies workload type (agent or tool)
        kagenti.io/spire: enabled     # Optional: Enable SPIFFE/SPIRE integration
    spec:
      containers:
      - name: app
        image: my-app:latest
```

### Per-Workload Control

**AuthBridge webhook** uses **pod labels** for control:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: force-injection-deployment
  namespace: other-namespace  # No namespace label
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: agent       # Required: Identifies workload type (agent or tool)
        kagenti.io/inject: enabled   # Explicit opt-in via pod label
        kagenti.io/spire: enabled    # Enable SPIRE integration
    spec:
      containers:
      - name: app
        image: my-app:latest
```

### SPIRE Integration Control

The AuthBridge webhook supports optional SPIRE integration. Use the `kagenti.io/spire` label on pod templates:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-with-spire
  namespace: my-apps
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: agent     # Required: Identifies workload type (agent or tool)
        kagenti.io/spire: enabled  # Enables spiffe-helper and client-registration sidecars
    spec:
      containers:
      - name: app
        image: my-app:latest
```

Without the `kagenti.io/spire: enabled` label, only the `proxy-init` and `envoy-proxy` containers are injected (no SPIRE integration).

### Injection Priority

1. **Required Type Label**: `kagenti.io/type: agent` or `kagenti.io/type: tool` - if this label is missing or has any other value, injection is skipped regardless of the other settings.
2. **Pod Label (opt-out)**: `kagenti.io/inject: disabled` - Explicitly disables injection when it would otherwise be enabled (for example, by namespace configuration).
3. **Pod Label (opt-in)**: `kagenti.io/inject: enabled` - Explicitly enables injection for this pod.
4. **Namespace Label**: `kagenti-enabled: "true"` - Namespace-wide enable (applies when the pod does not explicitly opt in or out via `kagenti.io/inject`).

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
├── injector/                    # Shared mutation logic
│   ├── pod_mutator.go          # Core mutation engine (InjectAuthBridge)
│   ├── container_builder.go    # Build sidecars & init containers
│   └── volume_builder.go       # Build volumes
└── v1alpha1/
    └── authbridge_webhook.go   # AuthBridge webhook handler
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
