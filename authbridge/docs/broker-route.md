# Broker Route Action

## Overview

AuthBridge supports a new outbound route action: `"broker"`. When an outbound request matches a route with this action, AuthBridge acquires a token from an external Token Broker service and injects it into the request. This is the third route action alongside `"exchange"` (RFC 8693 token exchange) and `"passthrough"` (no token handling).

The Token Broker is treated as a black box. AuthBridge calls a single blocking endpoint and receives a token. Any service that implements the expected API contract can serve as the Token Broker.

## Route Configuration

Add a `broker` route to `routes.yaml`:

```yaml
outbound:
  broker_url: "http://token-broker-service:8190"

routes:
  rules:
    - host: "target-service"
      action: "broker"
```

[`broker_url`](AuthBridge/authlib/config/config.go:35) is configured globally under [`outbound`](AuthBridge/authlib/config/config.go:30). Broker routes do not use [`target_audience`](AuthBridge/authlib/config/config.go:74) or [`token_scopes`](AuthBridge/authlib/config/config.go:75).

### Route Actions Summary

| Action | Purpose | Required Fields |
|--------|---------|-----------------|
| `exchange` (default) | RFC 8693 token exchange against an OAuth token endpoint | `target_audience`, `token_scopes` |
| `passthrough` | Forward request without token handling | (none) |
| `broker` | Acquire token from an external Token Broker | global [`broker_url`](AuthBridge/authlib/config/config.go:35) |

## How It Works

When an outbound request matches a `broker` route:

1. AuthBridge reads the outbound [`Authorization`](AuthBridge/authlib/auth/auth.go:308) header and extracts the bearer token.
2. The target server URL is derived from the request destination host.
3. AuthBridge calls [`POST {broker_url}/sessions/token`](AuthBridge/authlib/tokenbroker/client.go:31) with the original bearer token in [`Authorization`](AuthBridge/authlib/tokenbroker/client.go:38) and the derived target server URL in [`X-Server-Url`](AuthBridge/authlib/tokenbroker/client.go:39). This call **blocks** until a token is available or an error occurs.
4. On success, AuthBridge injects [`Authorization: Bearer {token}`](AuthBridge/cmd/authbridge/listener/extproc/server.go:140) into the forwarded request.
5. On broker failure, AuthBridge returns an MCP JSON-RPC error response to the caller.
6. No broker-specific request header from the agent is required or forwarded upstream.

The caller (AI Agent) never sees the token acquisition process.

## Token Broker API Contract

AuthBridge calls a single endpoint on the Token Broker:

```
POST {broker_url}/sessions/token
```

### Request Headers

| Header | Description |
|--------|-------------|
| `Authorization` | Bearer token from the outbound request |
| `X-Server-Url` | Target server URL |

### Success Response (200)

```json
{"token": "gho_xxxx"}
```

### Error Responses

| Status | Meaning |
|--------|---------|
| 401 | Session expired or user mismatch |
| 408 | Token acquisition timed out |
| 503 | Internal error |

The HTTP client timeout is 310 seconds, longer than the Token Broker's expected internal timeout of 300 seconds.

Any service implementing this contract is compatible with the `broker` route action.

## Error Handling

When token acquisition fails, AuthBridge returns an MCP JSON-RPC error:

```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32001,
    "message": "Failed to obtain user authorization for this MCP server."
  }
}
```

| Condition | HTTP Status | Cause |
|-----------|-------------|-------|
| Missing or malformed [`Authorization`](AuthBridge/authlib/auth/auth.go:308) header | 401 | Outbound request did not carry a valid bearer token |
| Token Broker returned an error | 403 | Broker could not acquire a token |
| No Token Broker client configured | 503 | Misconfiguration: broker flow was selected but no broker client was initialized |

## Configuration Validation

At startup, the router validates all routes:

- A broker configuration without global [`broker_url`](AuthBridge/authlib/config/config.go:35) cannot function correctly.
- A route with an unrecognized `action` value causes a startup error.

## Header Propagation

The caller must include an outbound [`Authorization`](AuthBridge/authlib/auth/auth.go:308) header for requests that will match a `broker` route.

AuthBridge derives the broker target server URL from the outbound request host in [`handleBroker()`](AuthBridge/authlib/auth/auth.go:300).

The ext_proc listener passes the outbound [`Authorization`](AuthBridge/cmd/authbridge/listener/extproc/server.go:86) header and destination host to [`HandleOutbound()`](AuthBridge/cmd/authbridge/listener/extproc/server.go:92). No agent-provided broker target header is used.

## Code Changes

| File | Change |
|------|--------|
| `authlib/routing/router.go` | Resolves [`"broker"`](AuthBridge/docs/broker-route.md:27) actions through the routing layer |
| `authlib/tokenbroker/client.go` | HTTP client for the Token Broker [`POST /sessions/token`](AuthBridge/authlib/tokenbroker/client.go:31) endpoint |
| `authlib/auth/auth.go` | Broker flow in [`handleBroker()`](AuthBridge/authlib/auth/auth.go:300); derives target URL and calls the broker |
| `authlib/auth/context.go` | [`ContextWithHeaders`](AuthBridge/docs/broker-route.md:117) / [`HeadersFromContext`](AuthBridge/docs/broker-route.md:117) for passing extra headers via context |
| `authlib/auth/result.go` | [`Broker bool`](AuthBridge/docs/broker-route.md:118) on outbound results to control broker-specific denial formatting |
| `authlib/config/config.go` | Global [`broker_url`](AuthBridge/authlib/config/config.go:35) in outbound config |
| `authlib/config/resolve.go` | Wires [`tokenbroker.NewClient()`](AuthBridge/docs/broker-route.md:119) and routing into the auth layer |
| `cmd/authbridge/listener/extproc/server.go` | Passes outbound authorization and host to auth handling and returns MCP JSON-RPC errors for broker denials |
