# Broker Route Action

## Overview

AuthBridge supports a new outbound route action: `"broker"`. When an outbound request matches a route with this action, AuthBridge acquires a token from an external Token Broker service and injects it into the request. This is the third route action alongside `"exchange"` (RFC 8693 token exchange) and `"passthrough"` (no token handling).

The Token Broker is treated as a black box. AuthBridge calls a single blocking endpoint and receives a token. Any service that implements the expected API contract can serve as the Token Broker.

## Route Configuration

Add a `broker` route to `routes.yaml`:

```yaml
- host: "mcp-server-service"
  action: "broker"
  token_broker_url: "http://token-broker-service:8190"
```

`token_broker_url` is required. `target_audience` and `token_scopes` are not used.

### Route Actions Summary

| Action | Purpose | Required Fields |
|--------|---------|-----------------|
| `exchange` (default) | RFC 8693 token exchange against an OAuth token endpoint | `target_audience`, `token_scopes` |
| `passthrough` | Forward request without token handling | (none) |
| `broker` | Acquire token from an external Token Broker | `token_broker_url` |

## How It Works

When an outbound request matches a `broker` route:

1. AuthBridge extracts `x-oauth-session-key` and `x-user-id` headers from the request.
2. The MCP server URL is derived from the request's destination host, or from the `x-mcp-server-url` header if present.
3. AuthBridge calls `POST {token_broker_url}/sessions/{session_key}/token` with the user ID and MCP server URL as headers. This call **blocks** until a token is available or an error occurs.
4. On success, AuthBridge injects `Authorization: Bearer {token}` into the request (same as the `exchange` action).
5. On failure, AuthBridge returns an MCP JSON-RPC error response to the caller.
6. Internal headers (`x-oauth-session-key`, `x-user-id`, `x-mcp-server-url`) are stripped from the request before it is forwarded upstream.

The caller (AI Agent) never sees the token acquisition process.

## Token Broker API Contract

AuthBridge calls a single endpoint on the Token Broker:

```
POST {token_broker_url}/sessions/{session_key}/token
```

### Request Headers

| Header | Description |
|--------|-------------|
| `X-User-ID` | User identifier for the token request |
| `X-Mcp-Server-Url` | Target MCP server URL |

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
| Missing `x-oauth-session-key` or `x-user-id` headers | 403 | Caller did not propagate required headers |
| Token Broker returned an error | 403 | Broker could not acquire a token |
| No Token Broker client configured | 503 | Misconfiguration: `broker` route exists but client was not initialized |

## Configuration Validation

At startup, the router validates all routes:

- A route with `action: "broker"` that is missing `token_broker_url` causes a startup error.
- A route with an unrecognized `action` value causes a startup error.

## Header Propagation

The caller must include `x-oauth-session-key` and `x-user-id` in outbound requests that will match a `broker` route. These headers are set by the Backend when forwarding tasks to the Agent and must be propagated through any Agent-to-Agent calls.

The ext_proc listener extracts these headers and passes them to `HandleOutbound` via context. No changes to Envoy configuration are required -- Envoy already sends all request headers to ext_proc.

## Code Changes

| File | Change |
|------|--------|
| `authlib/routing/router.go` | `Route` gains `TokenBrokerURL`; `ResolvedRoute` gains `Broker` + `TokenBrokerURL`; `Resolve` handles `"broker"`; `NewRouter` validates config |
| `authlib/tokenbroker/client.go` (new) | HTTP client for Token Broker `POST /sessions/{key}/token` endpoint |
| `authlib/auth/auth.go` | `tokenBrokerClient` field; `handleBroker` method; new branch in `HandleOutbound` before exchange logic |
| `authlib/auth/context.go` (new) | `ContextWithHeaders` / `HeadersFromContext` for passing extra headers via context |
| `authlib/auth/result.go` | `Broker bool` on `OutboundResult` (controls error format in ext_proc) |
| `authlib/config/config.go` | `TokenBrokerURL` on `RouteConfig`; `"broker"` as valid action |
| `authlib/config/resolve.go` | Wires `tokenbroker.NewClient()`; passes `TokenBrokerURL` through to routing |
| `cmd/authbridge/listener/extproc/server.go` | Extracts `x-oauth-session-key`, `x-user-id`, `x-mcp-server-url`; injects into context; strips before forwarding; MCP JSON-RPC error format for broker denials |
