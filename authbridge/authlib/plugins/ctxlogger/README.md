# ctx-logger

Read-only diagnostic plugin for AuthBridge. On every request and response — for
both the inbound and outbound legs — it logs the pipeline `Context`, with
emphasis on `pctx.Session`, at `INFO` level. It never blocks, denies, or mutates
anything: it always returns `Continue`.

Use it to answer *"what does `ctx.Session` (and the rest of the Context) contain
at this point in the pipeline?"* without touching the plugin you're
investigating. Place it next to that plugin (e.g. `opa`) so it observes the same
Context that plugin sees.

## How it works

1. The plugin registers itself as `ctx-logger` via `init()`.
2. It runs on both phases (`OnRequest`, `OnResponse`) on whichever leg(s) it is
   placed in.
3. Each invocation emits up to two structured `slog` lines at `INFO` (see
   [Log output](#log-output)), then returns `Continue`.

It is intentionally verbose at `INFO` so the output shows up in
`kubectl logs ... -c authbridge-proxy` without enabling debug logging. It reads
neither the request nor the response body (`Capabilities` declares no body
access).

## Configuration

The plugin takes no config. Add it to any pipeline leg by name:

```yaml
pipeline:
  inbound:
    plugins:
      - name: jwt-validation
        config: { ... }
      - name: ctx-logger        # observes the Context after jwt-validation
      - name: opa
        config: { ... }
  outbound:
    plugins:
      - name: ctx-logger        # observes the Context before token-exchange
      - name: token-exchange
        config: { ... }
```

Its position in the leg determines what it sees — place it *after* the plugins
whose contribution to the Context you want to inspect (e.g. after
`jwt-validation` to see `identity`, after a parser to see `ext_*`).

## Log output

### `ctx-logger: context`

A snapshot of the pipeline `Context`:

| Field | Notes |
|---|---|
| `phase` | `"request"` or `"response"` |
| `direction` | `"inbound"` or `"outbound"` |
| `method`, `host`, `path` | Request line context |
| `status_code` | `0` during the request phase |
| `identity_present` | `false` before an auth plugin runs and on the outbound leg |
| `identity_subject`, `identity_client_id`, `identity_scopes` | Populated from `pctx.Identity` when present, empty/nil otherwise |
| `agent_client_id` | SPIFFE-derived agent client ID, when set |
| `outbound_session_id` | |
| `session_present` | Whether `pctx.Session` is non-nil |
| `ext_a2a`, `ext_mcp`, `ext_inference` | Whether each protocol parser extension is attached |

### `ctx-logger: session`

The full session, serialized so its exact shape is visible per leg:

| Field | Notes |
|---|---|
| `session_id` | `pctx.Session.ID` |
| `event_count` | `len(pctx.Session.Events)` |
| `session_json` | The whole `SessionView` (ID + Events) as JSON |

Variants when the session can't be dumped normally:

- `ctx-logger: session is nil` — `pctx.Session == nil`.
- `ctx-logger: session present but not serializable` — JSON marshal failed;
  logs `session_id`, `events`, and `marshal_error` instead.
- `ctx-logger: nil context` — the whole `pctx` was nil.

## Binary availability

The plugin's side-effect import lives in
`cmd/authbridge-proxy/plugins_ctxlogger.go`, gated by
`//go:build !exclude_plugin_ctxlogger`. The default build includes it; building
with `-tags exclude_plugin_ctxlogger` drops it from the binary.

**envoy-sidecar mode does not link `ctx-logger` in.** The `cmd/authbridge-envoy`
binary has no `plugins_ctxlogger.go` shim, so the `ctxlogger` package is never
compiled into it. Referencing `ctx-logger` in an envoy-sidecar pipeline fails at
boot (unknown plugin). To use it there, add a matching shim under
`cmd/authbridge-envoy/`.

## Session events

None. `ctx-logger` is a pure observer — it emits log lines only and appends no
`Invocation` records, so it does not appear in the session events API (`:9094`)
or in `abctl`.
