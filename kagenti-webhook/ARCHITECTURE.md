# Kagenti Webhook Architecture

This document provides Mermaid diagrams illustrating the webhook architecture.

## Component Architecture

```mermaid
graph TB
    subgraph "Kubernetes API Server"
        API[API Server]
    end

    subgraph "Webhook Pod (kagenti-system)"
        MAIN[main.go]
        MUTATOR[PodMutator<br/>shared injector]

        subgraph "Webhook Handler"
            AUTH[AuthBridge Webhook]
        end

        subgraph "Builders"
            CONT[Container Builder<br/>proxy-init, envoy-proxy, spiffe-helper]
            VOL[Volume Builder]
        end
    end

    subgraph "Kubernetes Resources"
        subgraph "Standard Workloads"
            DEPLOY[Deployments]
            STS[StatefulSets]
            DS[DaemonSets]
            JOB[Jobs/CronJobs]
        end

        NAMESPACE[Namespace<br/>with labels/annotations]
    end

    API -->|mutate workloads| AUTH

    MAIN -->|creates & shares| MUTATOR
    MAIN -->|registers| AUTH

    AUTH -->|InjectAuthBridge| MUTATOR

    MUTATOR -->|builds containers| CONT
    MUTATOR -->|builds volumes| VOL
    MUTATOR -->|reads labels| NAMESPACE

    AUTH -.->|modifies| DEPLOY
    AUTH -.->|modifies| STS
    AUTH -.->|modifies| DS
    AUTH -.->|modifies| JOB

    style MUTATOR fill:#90EE90
    style AUTH fill:#32CD32,stroke:#006400,stroke-width:3px
    style CONT fill:#FFB6C1
    style VOL fill:#FFB6C1
    style DEPLOY fill:#87CEEB
    style STS fill:#87CEEB
    style DS fill:#87CEEB
    style JOB fill:#87CEEB
```

## Container Injection Flow

### With SPIRE Integration

When `kagenti.io/spire: enabled` label is set on the pod template:

```mermaid
graph LR
    subgraph "Pod Spec"
        APP[Application<br/>Container]
    end

    subgraph "AuthBridge Injection"
        INIT[proxy-init<br/>Init Container]
        ENVOY[envoy-proxy<br/>Sidecar]
        SPIFFE[spiffe-helper<br/>Sidecar]
        CLIENT[client-registration<br/>Sidecar]
    end

    subgraph "External Dependencies"
        SPIRE[SPIRE Agent]
        KC[Keycloak]
    end

    INIT -->|1. Setup iptables| ENVOY
    ENVOY -->|2. Proxy ready| APP
    SPIFFE -->|3. Get JWT-SVID| SPIRE
    SPIFFE -->|4. Write token| CLIENT
    CLIENT -->|5. Register| KC
    APP -->|All traffic via| ENVOY

    style INIT fill:#FFA500
    style ENVOY fill:#4169E1
    style SPIFFE fill:#32CD32
    style CLIENT fill:#9370DB
    style APP fill:#87CEEB
```

### Without SPIRE Integration

When `kagenti.io/spire` label is **not** set (default):

```mermaid
graph LR
    subgraph "Pod Spec"
        APP[Application<br/>Container]
    end

    subgraph "AuthBridge Injection"
        INIT[proxy-init<br/>Init Container]
        ENVOY[envoy-proxy<br/>Sidecar]
    end

    INIT -->|1. Setup iptables| ENVOY
    ENVOY -->|2. Proxy ready| APP
    APP -->|All traffic via| ENVOY

    style INIT fill:#FFA500
    style ENVOY fill:#4169E1
    style APP fill:#87CEEB
```

## Injection Decision Flow

```mermaid
graph TD
    START[Webhook Receives<br/>Admission Request]

    CHECK_TYPE{kagenti.io/type<br/>= agent or tool?}

    subgraph "AuthBridge Path (Recommended)"
        WORKLOAD[Standard Workload<br/>Deploy/STS/DS/Job]
        CHECK_NS_AB{Namespace has<br/>kagenti-enabled=true?}
        CHECK_LABEL{Pod has<br/>kagenti.io/inject=enabled}
        INJECT_FULL[Inject all sidecars<br/>per precedence chain<br/>proxy-init, envoy-proxy,<br/>spiffe-helper, client-registration]
    end

    subgraph "Legacy Path (Deprecated)"
        CUSTOM[Custom Resource<br/>Agent/MCPServer CR]
        CHECK_NS_LEG{Namespace has<br/>kagenti-enabled=true?}
        CHECK_ANNO{CR has<br/>kagenti.io/inject=enabled?}
        INJECT_SPIRE[Inject: spiffe-helper<br/>client-registration]
    end

    SKIP[Skip Injection]

    START --> CHECK_TYPE
    CHECK_TYPE -->|Workload| WORKLOAD
    CHECK_TYPE -->|CR| CUSTOM

    WORKLOAD --> CHECK_NS_AB
    CHECK_NS_AB -->|Yes| CHECK_LABEL
    CHECK_NS_AB -->|No| SKIP
    CHECK_LABEL -->|true| INJECT_FULL
    CHECK_LABEL -->|false| SKIP
    CHECK_LABEL -->|not set & ns=true| INJECT_FULL
    CHECK_LABEL -->|not set & ns=false| SKIP

    CUSTOM --> CHECK_NS_LEG
    CHECK_NS_LEG -->|Yes| CHECK_ANNO
    CHECK_NS_LEG -->|No| CHECK_ANNO
    CHECK_ANNO -->|true| INJECT_SPIRE
    CHECK_ANNO -->|false| SKIP
    CHECK_ANNO -->|not set & ns=true| INJECT_SPIRE
    CHECK_ANNO -->|not set & ns=false| SKIP

    style INJECT_FULL fill:#32CD32
    style INJECT_SPIRE fill:#D3D3D3,stroke:#808080,stroke-dasharray: 5 5
    style WORKLOAD fill:#87CEEB
    style CUSTOM fill:#D3D3D3,stroke:#808080,stroke-dasharray: 5 5
```

## Key Differences

| Aspect | AuthBridge (Recommended) | Legacy (Deprecated) |
|--------|--------------------------|---------------------|
| **Resources** | Standard K8s workloads | Custom Resources |
| **Injection Control** | Pod labels | CR annotations |
| **SPIRE** | Injected by default; opt out via `kagenti.io/spire: disabled` | Always enabled |
| **Containers** | Init: proxy-init<br/>Sidecars: envoy-proxy, spiffe-helper, client-registration | Sidecars: spiffe-helper, client-registration |
| **Traffic Management** | ✅ Envoy proxy with iptables | ❌ No proxy |
| **Authentication** | Multiple methods (SPIRE, mTLS, JWT, etc.) | SPIRE only |
| **Method** | `InjectAuthBridge()` | `MutatePodSpec()` |

spiffe-helper is injected by default; set `kagenti.io/spire: disabled` on the pod template to opt out.
```
