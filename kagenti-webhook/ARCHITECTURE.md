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
    CHECK_INJECT{kagenti.io/inject<br/>= enabled?}
    CHECK_SPIRE{kagenti.io/spire<br/>= enabled?}

    INJECT_FULL[Inject: proxy-init<br/>envoy-proxy, spiffe-helper<br/>client-registration]
    INJECT_BASIC[Inject: proxy-init<br/>envoy-proxy only]
    SKIP[Skip Injection]

    START --> CHECK_TYPE
    CHECK_TYPE -->|No| SKIP
    CHECK_TYPE -->|Yes| CHECK_INJECT
    CHECK_INJECT -->|enabled| CHECK_SPIRE
    CHECK_INJECT -->|other / missing| SKIP

    CHECK_SPIRE -->|Yes| INJECT_FULL
    CHECK_SPIRE -->|No| INJECT_BASIC

    style INJECT_FULL fill:#32CD32
    style INJECT_BASIC fill:#4169E1
    style SKIP fill:#D3D3D3
```
