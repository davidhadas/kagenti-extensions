# authbridge-compose-insecure

Run one or more agents, each with its own AuthBridge sidecar, on plain
Docker/Podman Compose — no Kind, no Kubernetes.

> **⚠ This setup is insecure — for desktop use only.** Every agent runs on one
> flat `shared` network alongside its AuthBridge sidecar. Traffic goes through
> the sidecar only because the agent is **configured** to (`HTTP_PROXY` for
> egress; callers use the reverse-proxy address for inbound). An agent *can*
> bypass its sidecar — the app's `:8000` port is reachable directly on `shared`,
> the agent can egress directly, and non-HTTP traffic is not captured at all.
> Do not rely on the sidecar as a security boundary here. For an isolated
> variant, use `authbridge-compose` (each agent on its own internal network).

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

- Docker with Compose v2.20+, **or** Podman with podman-compose
- Ollama on the host, or another OpenAI-compatible LLM endpoint
- A GitHub OAuth App (`GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET`)
- A local checkout of [`kagenti-operator`](https://github.com/kagenti/kagenti-operator),
  which supplies the **token-broker** source (see [Dependencies](#dependencies)).

**Create a GitHub OAuth App** at https://github.com/settings/developers:
- Homepage URL: `http://localhost:3000`
- Authorization callback URL: `http://localhost:8190/oauth/callback`

## Dependencies

Every service is either a **pre-built image** pulled from a registry, **built
from this directory**, or **built from a local `kagenti-operator` clone**.

| Service | How it's provided | Source |
|---|---|---|
| `agent-git-issue` | Pre-built image | `ghcr.io/kagenti/agent-examples/git_issue_agent:latest` (override `GIT_ISSUE_AGENT_IMAGE`) |
| `agent-weather` | Pre-built image | `ghcr.io/kagenti/agent-examples/weather_service:latest` (override `WEATHER_AGENT_IMAGE`) |
| `agent-claude` | Pre-built image | `ghcr.io/kagenti/agent-examples/claude_agent:latest` (override `CLAUDE_AGENT_IMAGE`) |
| `authbridge-<agent>` | Pre-built image | `ghcr.io/kagenti/kagenti-extensions/authbridge:latest` |
| `github-mcp` | Pre-built image | `ghcr.io/github/github-mcp-server:v1.1.2` |
| `weather-tool-mcp` | Pre-built image | `ghcr.io/kagenti/agent-examples/weather_tool:latest` (override `WEATHER_TOOL_IMAGE`) |
| registrars, `broker-routes-assemble` | Pre-built image | `busybox` |
| `bundle-server` | Built locally | `./bundle-server` |
| `rossocortex-frontend` | Built locally | `./rossocortex-ui/frontend` |
| `rossocortex-backend` | Built locally | `./rossocortex-ui/backend` |
| `token-broker` | Built from a local `kagenti-operator` clone | `${CODE_DIR}/kagenti-operator/token-broker` |

**Agents are standard, pre-built images** from the
[`agent-examples`](https://github.com/kagenti/agent-examples) repo. To pin a tag
or point at a local build, set the per-agent `*_AGENT_IMAGE` override in `.env`.

**The token-broker is built from the `kagenti-operator` repo.** Its Dockerfile
lives under `token-broker/` in that repo. Set `CODE_DIR` to the parent directory
of your `kagenti-operator` checkout; Compose builds the image from
`${CODE_DIR:-/Users/davidhadas/Code}/kagenti-operator/token-broker`.

## Quick start

```bash
# 1. Get the token-broker source (from the kagenti-operator repo). Clone it next
#    to your other checkouts; its parent directory is what CODE_DIR points at.
cd ~/Code                                      # or wherever you keep CODE_DIR
git clone https://github.com/kagenti/kagenti-operator.git
cd kagenti-extensions/authbridge/authbridge-compose-insecure

# 2. Configure
cp .env.example .env
# Edit .env — fill in GITHUB_OAUTH_CLIENT_ID, GITHUB_OAUTH_CLIENT_SECRET, the
#             LLM settings, and CODE_DIR (parent dir of your kagenti-operator
#             checkout — used to build the token-broker image).

# 3. Build and start
docker compose up --build      # Docker
# ./podman-up.sh up --build    # Podman (see note below)

# 4. Open the chat UI
open http://localhost:3000

# 5. Ask something, e.g.:
#    "List the 5 most-commented open issues in kubernetes/kubernetes"
#    The first MCP call triggers a GitHub OAuth popup; authorize once.
```

Tear down with `docker compose down` (or `./podman-up.sh down`).

**Podman note:** podman-compose does not support `include:`, so use the
`./podman-up.sh` wrapper for every compose subcommand (`up`, `down`, `logs`,
`config`, …). Set `COMPOSE=docker` to force the Docker CLI.

## Project layout

```
authbridge-compose-insecure/
├── docker-compose.yaml     # shared services + the `include:` list of agents & tools
├── podman-up.sh            # podman-compose wrapper
├── agents/                 # one file per agent (authbridge + agent + registrar, all on shared)
├── tools/                  # one file per tool (the MCP server + a broker-route registrar)
├── authbridge-config.yaml  # shared AuthBridge config, reused by every agent
├── bundle-server/          # OPA bundle server + starter policies (inbound + outbound)
└── rossocortex-ui/         # React SPA (frontend) + BFF (backend)
```

Agents and tools are discovered from the `include:` list in
`docker-compose.yaml`. Agents appear in the UI automatically: each agent's
registrar publishes a descriptor into a shared `registry` volume that the BFF
scans at request time.

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

1. Copy an existing agent file:
   ```bash
   cp agents/git-issue.yaml agents/<name>.yaml
   ```
   In `agents/<name>.yaml`:
   - Rename the three services (`authbridge-<name>`, `agent-<name>`,
     `registrar-<name>`). All services run on `shared`; there is no per-agent
     network.
   - Point `agent-<name>` at its **pre-built image** (`image:` line) — agents are
     standard images from [`agent-examples`](https://github.com/kagenti/agent-examples).
     Keep the `${..._AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/...}` override
     pattern so a tag or local build can be pinned via `.env`.
   - Set the `x-agent-identity` anchor (`AGENT_ID`, `AGENT_DESCRIPTION`) and the
     authbridge `AGENT_NAME` / `AGENT_PORT`.
   - Set the registrar's `AGENT_ENDPOINT` to `http://authbridge-<name>:8080` and
     its output file to `/registry/<name>.json`.
   - Give the authbridge instance **unique host ports** — `9000/9093/9094` are
     taken by git-issue; use e.g. `9001/9095/9096` for the next agent.

2. Add one line to the `include:` list in `docker-compose.yaml`:
   ```yaml
   include:
     - agents/git-issue.yaml
     - agents/<name>.yaml
   ```

On the next `up`, the agent's registrar publishes it and it appears in the UI.

## Removing an agent

Delete its `agents/<name>.yaml` file and remove its line from the `include:`
list in `docker-compose.yaml`, then re-run `up`. (Run
`docker compose down --volumes` first, or delete `/registry/<name>.json` from
the `registry` volume, so the UI stops listing it.)

## Mounting a host directory into an agent

Add a `volumes:` entry to the `agent-<name>` service in its
`agents/<name>.yaml`. For example, `agents/claude.yaml` bind-mounts
`~/mounts/claude` into `/workspace` read-write:

```yaml
  agent-claude:
    build:
      context: ...
    environment:
      ...
    volumes:
      - ${HOME}/mounts/claude:/workspace:rw
    networks:
      - shared
```

Notes:
- Create the host directory first (`mkdir -p ~/mounts/claude`) — a missing bind
  source is created by the runtime as a root-owned directory.
- Use `:ro` instead of `:rw` for a read-only mount.
- `${HOME}` is expanded by both runtimes; `~` is **not** expanded inside compose
  YAML. For a path relative to the compose root, use `${COMPOSE_ROOT:-..}`.

## Adding a tool

A tool is an MCP server the agents can call.

1. Copy an existing tool file:
   ```bash
   cp tools/github-mcp.yaml tools/<name>.yaml
   ```
   In `tools/<name>.yaml`:
   - Rename the server service and the `registrar-tool-<name>` service.
   - Point the server at the right image / command / port.
   - In the registrar, set the route fragment: `host` is the short service name
     agents will use in their `MCP_URL` Host header, plus the tool's
     `authorization_endpoint` / `token_endpoint`. Write it to
     `/routes/<name>.frag.yaml`.

2. Add one line to the `include:` list in `docker-compose.yaml`:
   ```yaml
   include:
     - agents/git-issue.yaml
     - tools/github-mcp.yaml
     - tools/<name>.yaml
   ```

3. Add the tool's OAuth scopes to `RESOURCE_CONFIG` on the `token-broker`
   service in `docker-compose.yaml`:
   ```yaml
   RESOURCE_CONFIG: >-
     {
       "http://github-mcp:8082": { ... },
       "http://<name>:<port>": {
         "scopes": ["..."],
         "authorization_endpoint": "https://.../authorize",
         "token_endpoint": "https://.../token"
       }
     }
   ```

4. Point the agent(s) that use the tool at it via their `MCP_URL`
   (in `agents/<agent>.yaml`).

5. List the new registrar under `broker-routes-assemble`'s `depends_on` in
   `docker-compose.yaml` so assembly waits for its fragment.

Re-run `up` to pick up the new tool.

## Removing a tool

Delete its `tools/<name>.yaml` file, remove its `include:` line, its
`RESOURCE_CONFIG` entry, and its `broker-routes-assemble` `depends_on` entry
from `docker-compose.yaml`, and remove any `MCP_URL` references to it in agent
files. Re-run `up`.

## Customizing the OPA policy

Edit `bundle-server/policies/outbound/request.rego` (outbound calls) or
`bundle-server/policies/inbound/request.rego` (inbound requests), then restart
the bundle server:

```bash
docker compose restart bundle-server
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

The config is shared, so this applies to every agent. Restart the authbridge
instances (`docker compose restart authbridge-git-issue`) or rely on config
hot-reload.
