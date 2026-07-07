# Terminal Feature Plan

## Overview

Add a web-based terminal to the RossoCortex UI that opens a PTY session inside
an agent container. The terminal is embedded in the chat page (xterm.js in the
browser, WebSocket to the BFF, PTY on the backend via `podman exec`).

Only agents that explicitly declare a `terminal_command` in their YAML get the
terminal button. The first agent to support it is `claude` with command `claude`.

All compose services also get explicit `container_name` fields so names are
deterministic and never depend on compose's `_1` suffix convention.

---

## Sub-Tasks

---

### Sub-Task 1 — Add explicit `container_name` to all compose services

**Intent**  
Give every service a predictable, human-readable container name. This makes
`podman exec`, `podman logs`, and debugging consistent, and allows the backend
to reference container names without guessing.

**Expected Outcomes**  
- Every service in every compose YAML has an explicit `container_name`
- `podman ps` shows clean names without `_1` suffix
- Existing scripts and docs that reference the old names are updated

**Todo List**  
1. Add `container_name` to every service in `docker-compose.yaml` (token-broker,
   bundle-server, rossocortex-frontend, rossocortex-backend, broker-routes-assemble)
2. Add `container_name` to every service in `agents/git-issue.yaml`
   (authbridge-git-issue, agent-git-issue, registrar-git-issue)
3. Add `container_name` to every service in `agents/weather.yaml`
   (authbridge-weather, agent-weather, registrar-weather)
4. Add `container_name` to every service in `agents/claude.yaml`
   (authbridge-claude, agent-claude, registrar-claude)
5. Add `container_name` to every service in `tools/github-mcp.yaml`
   (github-mcp, registrar-tool-github-mcp)
6. Add `container_name` to every service in `tools/weather-tool.yaml`
   (weather-tool-mcp)
7. Update `podman-up.sh` volume pre-create/remove loop — it references
   `authbridge-compose_registry` and `authbridge-compose_broker_routes`; verify
   volume names are unaffected (volumes are named separately from containers)

**Relevant Context**  
- All compose YAML files: `docker-compose.yaml`, `agents/*.yaml`, `tools/*.yaml`
- `podman-up.sh` — references container/volume names in the Created-state nudge loop
- Naming convention to use: drop the `authbridge-compose_` prefix and `_1` suffix,
  keep service name as-is (e.g. `agent-claude`, `authbridge-git-issue`)

**Status** `[x] done`

---

### Sub-Task 2 — Add terminal metadata to agent YAML and registry descriptor

**Intent**  
Allow agents to declare a terminal command in their YAML. The registrar writes
this into the registry descriptor so the backend can expose it in the agent API
and the frontend can show/hide the terminal button accordingly.

**Expected Outcomes**  
- `agents/claude.yaml` declares `TERMINAL_COMMAND: claude` and `TERMINAL_CONTAINER: agent-claude`
  in the registrar's environment, which writes them into the registry JSON
- `agents/git-issue.yaml` and `agents/weather.yaml` write no terminal fields
  (terminal button hidden for those agents)
- `GET /api/v1/agents` response includes `terminal_command` and `terminal_container`
  fields (null/absent for agents without a terminal)
- TypeScript `Agent` type extended with optional `terminal_command` and
  `terminal_container` fields

**Todo List**  
1. In `agents/claude.yaml`, add `TERMINAL_COMMAND` and `TERMINAL_CONTAINER` env
   vars to the registrar service and update the registrar `printf` command to
   include them in the JSON output
2. In `backend/main.py`, pass `terminal_command` and `terminal_container` through
   from registry JSON into the `GET /api/v1/agents` response items
3. In `frontend/src/types.ts`, add optional `terminal_command?: string` and
   `terminal_container?: string` to the `Agent` interface

**Relevant Context**  
- `agents/claude.yaml` — registrar service writes `{"name":…,"description":…,"url":…}`
- `backend/main.py` `_load_agents()` and `list_agents()` — where fields are read
  and serialised
- `frontend/src/types.ts` — `Agent` interface

**Status** `[x] done`

---

### Sub-Task 3 — Backend WebSocket PTY endpoint

**Intent**  
Add a WebSocket endpoint to the BFF that opens a PTY inside the named agent
container using `podman exec -it` and bidirectionally streams raw bytes between
the PTY and the WebSocket. This gives the browser a real TTY — full color,
signals, resize, interactive programs.

**Expected Outcomes**  
- `GET /api/v1/terminal/{container}/{command}` upgrades to WebSocket
- Backend spawns `podman exec -it <container> <command>` in a PTY
  (using the `ptyprocess` or `asyncio` subprocess with a pseudo-terminal)
- Raw bytes from PTY → WebSocket; bytes from WebSocket → PTY stdin
- Terminal resize messages (JSON `{"type":"resize","cols":N,"rows":N}`) handled
  via `fcntl.ioctl(TIOCSWINSZ)`
- PTY exit closes the WebSocket cleanly
- WebSocket disconnect kills the PTY process

**Todo List**  
1. Add `websockets` and `ptyprocess` (or use `os.openpty` + asyncio) to
   `backend/requirements.txt` (or `pyproject.toml`)
2. Add the WebSocket endpoint to `backend/main.py` — upgrade HTTP → WS,
   spawn PTY, run two async tasks: PTY→WS reader and WS→PTY writer
3. Handle resize: detect JSON messages `{"type":"resize","cols":N,"rows":N}`
   on the WS and call `ioctl(TIOCSWINSZ)` on the PTY fd
4. Handle disconnect: on WS close, kill the PTY process and clean up the fd
5. Update `nginx.conf` to proxy WebSocket connections
   (`proxy_http_version 1.1`, `Upgrade`, `Connection` headers) for the
   `/api/` location block

**Relevant Context**  
- `backend/main.py` — FastAPI app; WebSocket support is built into FastAPI/Starlette
- `rossocortex-ui/frontend/nginx.conf` — nginx proxy; needs WS upgrade headers
- Container accessible by name on the shared Docker network; `podman` binary
  is available on the host but NOT inside the backend container — the exec
  must be done from the host or via the Docker socket
- **Important**: the backend runs inside a container. To `podman exec` into
  another container it needs either the Docker/Podman socket mounted, or the
  exec must be triggered differently. The plan must address this.

**Status** `[x] done`

---

### Sub-Task 4 — Frontend terminal panel (xterm.js)

**Intent**  
Add an xterm.js terminal panel to the chat page that opens when the user
clicks the terminal button. The panel connects to the backend WebSocket,
streams bytes bidirectionally, and handles terminal resize.

**Expected Outcomes**  
- "Terminal" button appears in the chat page header (next to "New session")
  only when `agent.terminal_command` is set
- Clicking it opens an xterm.js terminal panel below the chat area (or as
  an overlay/drawer)
- Terminal connects to `ws://localhost:3000/api/v1/terminal/{container}/{command}`
- Typing in xterm.js sends bytes to the PTY; PTY output renders in xterm.js
- Terminal resizes when the panel resizes (uses xterm.js FitAddon +
  ResizeObserver to send `{"type":"resize","cols":N,"rows":N}` to the WS)
- Closing the panel disconnects the WebSocket and kills the PTY

**Todo List**  
1. Add `xterm` and `@xterm/addon-fit` to `frontend/package.json`
2. Create `frontend/src/components/TerminalPanel.tsx` — mounts xterm.js,
   opens WebSocket, wires data flow, handles resize via FitAddon +
   ResizeObserver, cleans up on unmount
3. In `ChatPage.tsx`, add terminal open/close state, add "Terminal" button
   (hidden if `!agent?.terminal_command`), render `<TerminalPanel>` when open
4. Style the terminal panel (dark background, monospace, reasonable default
   height, scrollable)

**Relevant Context**  
- `frontend/src/pages/ChatPage.tsx` — where the button and panel go
- `frontend/src/components/AppLayout.tsx` — for style reference
- `frontend/src/styles/global.css` — design tokens (dark bg: `--kagenti-masthead-bg: #151515`)
- xterm.js docs: `Terminal`, `FitAddon`, `ITerminalOptions`

**Status** `[x] done`

---

### Sub-Task 5 — Docker socket access for the backend container

**Intent**
The backend container needs to exec into sibling containers. This requires
mounting the Podman socket into the backend container and using the `docker`
Python SDK (which speaks the Docker/Podman REST API) — no CLI binary needed
inside the image.

**Expected Outcomes**
- `rossocortex-backend` service in `docker-compose.yaml` mounts the Podman
  socket at a fixed path inside the container (e.g. `/var/run/podman.sock`)
- `docker` Python SDK added to backend dependencies
- Backend creates a `docker.DockerClient(base_url="unix:///var/run/podman.sock")`
  and can call `container.exec_run(...)` on sibling containers by name
- No `podman` or `docker` CLI binary needed inside the backend image

**Todo List**
1. Find the Podman rootless socket path on the host:
   `podman info --format '{{.Host.RemoteSocket.Path}}'`
2. Add the socket bind-mount to `rossocortex-backend` in `docker-compose.yaml`,
   mapping host socket → `/var/run/podman.sock` inside the container;
   expose the path as `PODMAN_SOCKET_PATH` env var for flexibility
3. Add `docker` Python SDK to `rossocortex-ui/backend/requirements.txt`
   (or equivalent deps file)
4. Add a startup check in `backend/main.py` that verifies the socket is
   reachable; log a clear warning if not (terminal feature will be unavailable)

**Relevant Context**
- `docker-compose.yaml` — `rossocortex-backend` service definition
- `rossocortex-ui/backend/Dockerfile` — backend image build (no CLI change needed)
- Podman rootless socket path: `podman info --format '{{.Host.RemoteSocket.Path}}'`
- `docker` SDK exec API: `client.containers.get(name).exec_run(cmd, tty=True, socket=True)`

**Status** `[x] done`

---

## Implementation Order

Sub-tasks must be done in this order:

```
1 (container_name) → 2 (YAML metadata) → 5 (socket access) → 3 (WS PTY backend) → 4 (frontend)
```

Sub-task 5 is a prerequisite for 3 (backend can't exec without socket access).
Sub-tasks 3 and 4 can be developed in parallel once 5 is done, but 4 requires
3 to be running to test end-to-end.
