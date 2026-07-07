# authbridge-docker-insecure

Run one or more agents, each with its own AuthBridge sidecar, on plain
`docker` **or** `podman` — no Compose, no Kind, no Kubernetes. A single
`./run.sh` brings the whole stack up; every agent, tool, and service is one
self-contained file you can add or remove without touching the launcher.

> **⚠ This setup is insecure — for desktop use only.** Every agent runs on one
> flat `shared` network alongside its AuthBridge sidecar. Traffic goes through
> the sidecar only because the agent is **configured** to (`HTTP_PROXY` for
> egress; callers use the reverse-proxy address for inbound). An agent *can*
> bypass its sidecar — the app's `:8000` port is reachable directly on `shared`,
> the agent can egress directly, and non-HTTP traffic is not captured at all.
> Do not rely on the sidecar as a security boundary here.

## Architecture

```
Browser
  │
  ▼
rossocortex-frontend :3000  ──►  rossocortex-backend (BFF)
  (React SPA)                      │  POST /api/v1/chat/...
                                   ▼
                          authbridge-<agent> :8080  (reverse proxy, shared net)
                                   │            ⚠ agent:8000 ALSO reachable directly
                            agent-<agent> :8000     (shared net — NOT isolated)
                                   │  HTTP_PROXY=http://authbridge-<agent>:8081
                                   │            ⚠ agent can ALSO egress directly
                                   ▼
                          authbridge-<agent> :8081  (forward proxy)
                            outbound pipeline:
                            mcp-parser → a2a-parser → opa → token-broker
                                   │
                          github-mcp :8082          (official GitHub MCP server, shared net)

token-broker  :8190  ◄──────────  token-broker plugin (HITL OAuth)
bundle-server :8090  ◄──────────  opa plugin (policy bundles, inbound + outbound)
```

The **inbound** pipeline (requests arriving at the agent) runs `a2a-parser` →
`opa` (policy `authbridge.inbound.request`, default allow). To also validate
JWTs, see [Adding inbound JWT validation](#adding-inbound-jwt-validation).

**GitHub OAuth (HITL) flow**: the first time an agent calls `github-mcp`, the
`token-broker` plugin pauses the call and asks the token-broker service for a
GitHub OAuth URL. The UI shows it as a banner and opens an OAuth popup; once you
authorize, GitHub redirects to `/oauth/callback`, the plugin is unblocked, and
subsequent calls reuse the cached token.

## Prerequisites

- `docker` **or** `podman` on PATH (nothing else — no Compose)
- Ollama on the host, or another OpenAI-compatible LLM endpoint
- A GitHub OAuth App (`GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET`)
- A local checkout of [`kagenti-operator`](https://github.com/kagenti/kagenti-operator),
  which supplies the **token-broker** source (see [Dependencies](#dependencies)).

**Create a GitHub OAuth App** at https://github.com/settings/developers:
- Homepage URL: `http://localhost:3000`
- Authorization callback URL: `http://localhost:8190/oauth/callback`

## Dependencies

Every unit is either a **pre-built image** pulled from a registry, **built from
this directory**, or **built from a local `kagenti-operator` clone**.

| Unit | How it's provided | Source |
|---|---|---|
| `agent-git-issue` | Pre-built image | `ghcr.io/kagenti/agent-examples/git_issue_agent:latest` (override `GIT_ISSUE_AGENT_IMAGE`) |
| `agent-weather` | Pre-built image | `ghcr.io/kagenti/agent-examples/weather_service:latest` (override `WEATHER_AGENT_IMAGE`) |
| `agent-claude` | Pre-built image | `ghcr.io/kagenti/agent-examples/claude_agent:latest` (override `CLAUDE_AGENT_IMAGE`) |
| `authbridge-<agent>` | Pre-built image | `ghcr.io/kagenti/kagenti-extensions/authbridge:latest` |
| `github-mcp` | Pre-built image | `ghcr.io/github/github-mcp-server:v1.1.2` |
| `weather-tool-mcp` | Pre-built image | `ghcr.io/kagenti/agent-examples/weather_tool:latest` (override `WEATHER_TOOL_IMAGE`) |
| registrars, `broker-routes-assemble` | Pre-built image | `busybox` |
| `bundle-server` | Built locally | `bundle-server/` |
| `rossocortex-frontend` | Built locally | `rossocortex-ui/frontend/` |
| `rossocortex-backend` | Built locally | `rossocortex-ui/backend/` |
| `token-broker` | Built from a local `kagenti-operator` clone | `${CODE_DIR}/kagenti-operator/token-broker` |

**Agents are standard, pre-built images** from the
[`agent-examples`](https://github.com/kagenti/agent-examples) repo. To pin a tag
or point at a local build, set the per-agent `*_AGENT_IMAGE` override in `.env`.

**The token-broker is built from the `kagenti-operator` repo.** Its Dockerfile
lives under `token-broker/` in that repo. Set `CODE_DIR` to the parent directory
of your `kagenti-operator` checkout; `run.sh` builds the image from
`${CODE_DIR:-/Users/davidhadas/Code}/kagenti-operator/token-broker`.

## Quick start

```bash
# 1. Get the token-broker source (from the kagenti-operator repo). Clone it next
#    to your other checkouts; its parent directory is what CODE_DIR points at.
cd ~/Code                                      # or wherever you keep CODE_DIR
git clone https://github.com/kagenti/kagenti-operator.git
cd kagenti-extensions/authbridge/authbridge-docker-insecure

# 2. Configure
cp .env.example .env
# Edit .env — fill in GITHUB_OAUTH_CLIENT_ID, GITHUB_OAUTH_CLIENT_SECRET, the
#             LLM settings, and CODE_DIR (parent dir of your kagenti-operator
#             checkout — used to build the token-broker image).
#             (For the claude agent: mkdir -p ~/mounts/claude)

# 3. Build and start (docker or podman, auto-detected)
./run.sh up --build

# 4. Open the chat UI
open http://localhost:3000

# 5. Ask something, e.g.:
#    "List the 5 most-commented open issues in kubernetes/kubernetes"
#    The first MCP call triggers a GitHub OAuth popup; authorize once.
```

Other commands:

```bash
./run.sh ps            # list stack containers
./run.sh logs <name>   # tail one container's logs
./run.sh down          # remove the stack (add --volumes to drop registry/broker_routes)
```

`run.sh` auto-detects the runtime (prefers `podman`, else `docker`). Force one
with `RUNTIME=docker ./run.sh up` or `RUNTIME=podman ./run.sh up`.

## Project layout

```
authbridge-docker-insecure/
├── run.sh                  # the launcher (docker OR podman); never edited to add/remove a unit
├── lib/helpers.sh          # helper functions the files call (run_container/build_and_run/oneshot)
├── services/*.sh           # one file per shared service (token-broker, bundle-server, UI, assemble)
├── agents/*.sh             # one file per agent (its AuthBridge sidecar + agent + registrar)
├── tools/*.sh              # one file per tool (the MCP server + a broker-route registrar if OAuth)
├── authbridge-config.yaml  # shared AuthBridge config, used by every sidecar
├── .env / .env.example     # single env source (secrets live here; .env is git-ignored)
├── bundle-server/          # OPA bundle server + starter policies (inbound + outbound)
└── rossocortex-ui/         # React SPA (frontend) + BFF (backend)
```

`run.sh` scans `services/*.sh`, `agents/*.sh`, and `tools/*.sh` and runs
whatever it finds — **adding a unit is dropping in one file; removing it is
deleting the file.** The launcher is never edited. Agents appear in the UI
automatically: each agent's registrar publishes a descriptor into a shared
`registry` volume that the BFF scans at request time.

## Services

| Service | Port | Purpose |
|---|---|---|
| `rossocortex-frontend` | 3000 | Chat UI (React SPA) |
| `rossocortex-backend` | — | BFF: auth, agent discovery, chat proxy, token-broker bridge |
| `authbridge-<agent>` | 9000→8080 | Reverse proxy (inbound to agent); 8081 forward proxy (on `shared`) |
| `authbridge-<agent>` | 9093 / 9094 | Stats + config reload / session events API (`abctl`) |
| `github-mcp` | 8082 | Official GitHub MCP server |
| `token-broker` | 8190 | HITL OAuth broker |
| `bundle-server` | 8090 | OPA policy bundle server |

## Adding an agent

Adding an agent is **one new file** — no launcher edit, no central list:

1. Copy an existing agent file:
   ```bash
   cp agents/git-issue.sh agents/<name>.sh
   ```
   In `agents/<name>.sh`, edit only that file:
   - `unit_name <name>` and the three container `--name`s (`agent-<name>`,
     `authbridge-<name>`, `registrar-<name>`).
   - `AGENT_ID` / `AGENT_DESCRIPTION`.
   - the agent's `--image` (the `${..._AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/...}`
     line) and its `MCP_URL` / LLM env.
   - the sidecar's proxy host in the agent's env (`http://authbridge-<name>:8081`).
   - **unique host ports** for the sidecar — `9000/9093/9094` are taken by
     git-issue, `9001/9095/9096` by weather, `9002/9097/9098` by claude; use the
     next free triple.
   - the registrar's `AGENT_ENDPOINT` (`http://authbridge-<name>:8080`) and its
     output file (`/registry/<name>.json`).

2. `./run.sh up --build`. The new file is picked up automatically and the agent
   appears in the UI.

## Removing an agent

Delete its `agents/<name>.sh` file, then `./run.sh down` and `./run.sh up`.
(Add `--volumes` to `down`, or delete `/registry/<name>.json`, so the UI stops
listing it.)

## Mounting a host directory into an agent

Add a `--mount` to the agent's `build_and_run` in its `agents/<name>.sh`. For
example `agents/claude.sh` bind-mounts `${HOME}/mounts/claude` into `/workspace`
read-write:

```sh
run_container --name agent-claude \
  --image "${CLAUDE_AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/claude_agent:latest}" \
  ...
  --mount "${HOME}/mounts/claude:/workspace:rw"
```

Notes:
- Create the host directory first (`mkdir -p ~/mounts/claude`) — a missing bind
  source is created by the runtime as a root-owned directory.
- Use `:ro` instead of `:rw` for a read-only mount.
- `${HOME}` is an ordinary shell expansion here, so `~` also works. The launcher
  adds the SELinux relabel suffix automatically on podman+Linux.

## Adding a tool

**Passthrough tool** (no OAuth) — one new file:

```bash
cp tools/weather-tool.sh tools/<name>.sh
```

Edit the `--name`, build `--context` (or `--image`), and `--port`, then
`./run.sh up --build`. Point the agent(s) at it via their `MCP_URL`.

**OAuth tool** — one new file **+ one shared edit**:

1. `cp tools/github-mcp.sh tools/<name>.sh` and edit the server (`--name`,
   `--image`/`--context`, `--port`, command) and the `oneshot` route fragment
   (`host` = the short service name agents use in `MCP_URL`; the tool's
   `authorization_endpoint` / `token_endpoint`; output `/routes/<name>.frag.yaml`).
2. Add the tool's OAuth scopes to `RESOURCE_CONFIG` in
   `services/token-broker.sh`:
   ```sh
   --env 'RESOURCE_CONFIG={"http://github-mcp:8082":{...},"http://<name>:<port>":{"scopes":["..."],"authorization_endpoint":"https://.../authorize","token_endpoint":"https://.../token"}}'
   ```
3. `./run.sh up --build`. The new fragment is folded into `broker-routes.yaml`
   automatically.

## Removing a tool

Delete its `tools/<name>.sh` file (and, for an OAuth tool, its `RESOURCE_CONFIG`
entry in `services/token-broker.sh`). Remove any `MCP_URL` references to it in
agent files, then `./run.sh down` and `./run.sh up`.

## Customizing the OPA policy

Edit `bundle-server/policies/outbound/request.rego` (outbound calls) or
`bundle-server/policies/inbound/request.rego` (inbound requests), then restart
the bundle server:

```bash
podman restart bundle-server    # or: docker restart bundle-server
```

The AuthBridge OPA plugin polls every 10–120 seconds and picks up the new policy.

Example — deny `delete_issue` MCP tool calls (outbound):

```rego
package authbridge.outbound.request

default allow := false

allow if { input.mcp.method != "tools/call" }
allow if {
    input.mcp.method == "tools/call"
    input.mcp.params.name != "delete_issue"
}
```

## Adding inbound JWT validation

The inbound pipeline runs `a2a-parser` + `opa`. To also validate JWTs, add a
`jwt-validation` entry **before** them in `authbridge-config.yaml`:

```yaml
pipeline:
  inbound:
    plugins:
      - name: jwt-validation
        config:
          issuer: "${ISSUER}"
      - name: a2a-parser
      - name: opa
        config:
          bundle_url: "http://bundle-server:8090"
          agent_id: "${AGENT_ID}"
```

The config is shared, so this applies to every agent. Restart the sidecars to
pick it up — `./run.sh down && ./run.sh up`, or restart one directly
(`podman restart authbridge-git-issue` / `docker restart …`) — or rely on config
hot-reload.
