"""
RossoCortex backend — BFF for the React SPA.

Endpoints:
  Auth (simulated IdP):
    POST /api/v1/auth/login          → {url} to the callback
    GET  /api/v1/auth/token?code=..  → {access_token}
    GET  /api/v1/auth/config         → {enabled, token_broker_enabled}
  Agents:
    GET  /api/v1/namespaces
    GET  /api/v1/agents
  Chat (async task model — non-blocking submit + poll):
    POST /api/v1/chat/{ns}/{name}/send   → 202 {task_id}  body: {message, session_id}
    GET  /api/v1/chat/result/{task_id}   → pending | done | error | 404
  Token-broker bridge:
    POST   /api/v1/token-broker/session
    GET    /api/v1/token-broker/ui-events   (long-poll, no timer)
    DELETE /api/v1/token-broker/session

Environment variables:
  ENV                "local" (default) permits alg:none dev tokens; any other
                     value aborts startup (Point 3 guard).
  TOKEN_BROKER_URL   token-broker base URL (required)
  DEMO_REDIRECT_URL  OAuth resume URL (default: http://localhost:3000/oauth-resume)
  AGENTS_REGISTRY_DIR  directory scanned for per-agent {name, description, url}
                       descriptor JSON files (default: /registry). Each agent's
                       registrar writes one file here, so the agent list is
                       derived from whichever agents are running.
"""

import asyncio
import base64
import json
import logging
import os
import pathlib
import time
import uuid

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from token_broker import TokenBrokerClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

TOKEN_BROKER_URL = os.environ["TOKEN_BROKER_URL"].rstrip("/")
REDIRECT_URL = os.environ.get("DEMO_REDIRECT_URL", "http://localhost:3000/oauth-resume")

# ── Point 3: alg:none guard ───────────────────────────────────────────────────
# This BFF mints unsigned (alg:none) JWTs for the simulated IdP. That is ONLY
# acceptable in a local dev demo where the token-broker also runs without
# JWKS verification. To prevent this insecure mode from silently reaching a
# non-local environment, ENV must be "local" (the default) to allow alg:none.
# Any other ENV value requires a real IdP (JWT_JWKS_URL on the token-broker)
# and this BFF must not be the token source — fail fast at startup.
ENV = os.environ.get("ENV", "local").lower()
if ENV != "local":
    raise RuntimeError(
        f"ENV={ENV!r}: the RossoCortex BFF mints unsigned alg:none JWTs and is "
        "for local demo use only. For non-local environments, use a real IdP "
        "(set JWT_JWKS_URL on the token-broker) and do not run this BFF as the "
        "token source. Set ENV=local only for local demos."
    )

# Agent discovery: each running agent's registrar drops a descriptor file
# {"name": str, "description": str, "url": str} into AGENTS_REGISTRY_DIR. The
# agent list is derived by scanning that directory at request time, so agents
# added via `docker compose up` (or removed) show up without a BFF restart.
# All agents share the single "compose" namespace.
AGENTS_REGISTRY_DIR = os.environ.get("AGENTS_REGISTRY_DIR", "/registry")


def _load_agents() -> list[dict]:
    """Read every *.json descriptor from the registry dir. Cheap enough to
    call per request — a handful of tiny files."""
    agents: list[dict] = []
    d = pathlib.Path(AGENTS_REGISTRY_DIR)
    if d.is_dir():
        for f in sorted(d.glob("*.json")):
            try:
                agents.append(json.loads(f.read_text()))
            except Exception:
                log.error("skipping unreadable agent descriptor %s", f)
    return agents


# ── Agent card cache ──────────────────────────────────────────────────────────
# Fetched once per agent URL (cards are static for the container lifetime).
# Falls back to {} on any error so the agent list never breaks.
_card_cache: dict[str, dict] = {}

async def _fetch_agent_card(url: str) -> dict:
    """GET /.well-known/agent.json from the agent's internal URL.
    Result is cached in-process; returns {} on any network/parse error."""
    if url in _card_cache:
        return _card_cache[url]
    card_url = url.rstrip("/") + "/.well-known/agent.json"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(card_url)
        if resp.is_success:
            card = resp.json()
            _card_cache[url] = card
            return card
    except Exception as exc:
        log.warning("could not fetch agent card from %s: %s", card_url, exc)
    _card_cache[url] = {}
    return {}


def _card_tags(card: dict) -> list[str]:
    """Flatten tags from all skills in the card."""
    tags: list[str] = []
    for skill in card.get("skills") or []:
        tags.extend(skill.get("tags") or [])
    return list(dict.fromkeys(tags))  # deduplicate, preserve order


def _card_examples(card: dict) -> list[str]:
    """Collect example prompts from all skills in the card."""
    examples: list[str] = []
    for skill in card.get("skills") or []:
        examples.extend(skill.get("examples") or [])
    return examples


def _card_security(card: dict) -> bool:
    """True if the card declares any securitySchemes."""
    return bool(card.get("securitySchemes"))


app = FastAPI(title="RossoCortex backend")

# ── Token-broker session state (one session per backend process) ─────────────
_client: TokenBrokerClient | None = None
_jwt: str | None = None
_event_queue: asyncio.Queue | None = None
_poll_task: asyncio.Task | None = None

# Sentinel event pushed into a queue on cleanup to wake any /ui-events request
# blocked on it, so the frontend reconnects to the new session's queue.
_SESSION_ENDED = {"type": "session_ended"}

def _tag(jwt: str | None) -> str:
    """Short correlation tag from a JWT's jti claim (for log matching)."""
    if not jwt:
        return "none"
    try:
        payload = jwt.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return str(claims.get("jti", "?"))[:8]
    except Exception:
        return "?"


async def _cancel_session_tasks(jwt: str) -> None:
    """Cancel every in-flight agent task belonging to the session being torn
    down. Cancelling closes the BFF→agent httpx connection; combined with the
    broker end_session below (which closes session.Done and unblocks the
    agent's AcquireToken), the agent is freed for the next session.

    Each cancelled task's CancelledError handler sets its 'done' Event, so a
    blocked /chat/result long-poll returns {status: error, detail: cancelled}
    and the UI stops spinning."""
    tag = _tag(jwt)
    for task_id, entry in list(_tasks.items()):
        if entry.get("jti") != jwt:
            continue
        t: asyncio.Task | None = entry.get("_task")
        if t and not t.done():
            log.info("[session %s] cleanup: cancelling in-flight task %s", tag, task_id)
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
            except Exception:
                pass


async def _cleanup() -> None:
    """Total teardown of the current session — the SINGLE choke point that
    guarantees ZERO leftovers, in the BFF *and* at the token broker. Every
    session-replace path (implicit replace in _open_session, new_session,
    end_session, shutdown) goes through here, so none can skip a step:

      1. Cancel every in-flight agent task for this session (frees the agent).
      2. End the session at the token broker (broker is left clean; closing
         session.Done also unblocks any stuck AcquireToken in the agent).
      3. Cancel the poll loop and drop the queue.
      4. Wake any /ui-events request blocked on the old queue via the
         session_ended sentinel, so the frontend reconnects to the new session.
    """
    global _jwt, _event_queue, _poll_task
    old_jwt = _jwt
    tag = _tag(old_jwt)
    log.info("[session %s] cleanup", tag)

    # 1. Cancel in-flight agent tasks belonging to this session (frees the agent).
    if old_jwt is not None:
        await _cancel_session_tasks(old_jwt)

    # 2. End the broker session so the token broker is clean too. This is done
    #    here (not in the callers) so NO replace path can leave a broker orphan.
    if _client is not None and old_jwt is not None:
        try:
            await _client.end_session(old_jwt)
            log.info("[session %s] cleanup: broker session ended", tag)
        except Exception as exc:
            log.warning("[session %s] cleanup: broker end_session error: %s", tag, exc)

    # 3. Cancel the poll loop.
    if _poll_task and not _poll_task.done():
        _poll_task.cancel()
        try:
            await _poll_task
        except asyncio.CancelledError:
            pass
    # 4. Release any blocked /ui-events reader on the old queue.
    if _event_queue is not None:
        _event_queue.put_nowait(_SESSION_ENDED)
    _poll_task = None
    _event_queue = None
    _jwt = None


async def _polling_loop(jwt: str, queue: asyncio.Queue) -> None:
    """Long-poll the broker for events. Keeps looping (with backoff) on error
    so a transient broker outage self-heals — this loop's liveness IS the
    session health signal the SPA observes via /ui-events.

    Cancellation: _cleanup() cancels this task when a new session starts. We
    let CancelledError propagate so the old loop stops immediately and never
    polls a stale session's JWT.
    """
    tag = _tag(jwt)
    log.info("[session %s] poll loop STARTED", tag)
    backoff = 1.0
    while True:
        try:
            t0 = time.monotonic()
            event = await _client.poll_events(jwt)
            dt = time.monotonic() - t0
            backoff = 1.0  # healthy poll — reset backoff
            if event is None:
                log.info("[session %s] broker-events: no event (%.1fs) → re-poll", tag, dt)
            else:
                log.info("[session %s] broker-events: event=%s (%.1fs) → enqueue",
                         tag, event.get("type", "unknown"), dt)
                await queue.put(event)
        except asyncio.CancelledError:
            log.info("[session %s] poll loop CANCELLED (session replaced)", tag)
            raise
        except Exception as exc:
            # Real broker failure (connection/HTTP error). Surface to the SPA
            # (marks unhealthy) but KEEP LOOPING so we recover when it returns.
            log.warning("[session %s] broker-events ERROR (retry in %.0fs): %s",
                        tag, backoff, exc)
            await queue.put({"type": "error", "error": str(exc)})
            try:
                await asyncio.sleep(backoff)
            except asyncio.CancelledError:
                log.info("[session %s] poll loop CANCELLED during backoff", tag)
                raise
            backoff = min(backoff * 2, 10.0)


async def _open_session(jwt: str, redirect_url: str) -> bool:
    """Single path for opening a token-broker session + poll loop.

    Reuses an existing session for the same jwt (same jti) rather than
    tearing it down — avoids breaking an in-progress token acquisition.
    Returns True on success (created or reused), False on broker failure.
    """
    global _jwt, _event_queue, _poll_task
    tag = _tag(jwt)

    if _jwt == jwt and _poll_task and not _poll_task.done():
        log.info("[session %s] open: already active → REUSE", tag)
        return True

    log.info("[session %s] open: creating new session (replacing %s)", tag, _tag(_jwt))
    await _cleanup()
    ok = await _client.create_session(jwt, redirect_url)
    if not ok:
        log.warning("[session %s] open: broker create_session FAILED", tag)
        return False
    _jwt = jwt
    _event_queue = asyncio.Queue()
    _poll_task = asyncio.create_task(_polling_loop(jwt, _event_queue))
    log.info("[session %s] open: session CREATED", tag)
    return True


@app.on_event("startup")
async def startup() -> None:
    global _client
    _client = TokenBrokerClient(TOKEN_BROKER_URL)


@app.on_event("shutdown")
async def shutdown() -> None:
    # _cleanup() ends the broker session and cancels in-flight tasks.
    await _cleanup()
    if _client:
        await _client.close()


# ── Simulated IdP auth ────────────────────────────────────────────────────────
# Mirrors the Keycloak flow shape so AuthContext works identically to the
# original app-demo. No real IdP — login is instant and always succeeds.
#
# Flow:
#   1. Frontend calls POST /api/v1/auth/login  → gets {"url": "/auth/callback?code=X"}
#   2. Frontend redirects to /auth/callback (React route)
#   3. /auth/callback calls GET /api/v1/auth/token?code=X → gets {"access_token": JWT}
#   4. Frontend stores JWT, sets authenticated=true, calls createSession() once

# One-time-use codes: code → jti mapping, consumed on token exchange.
_pending_codes: dict[str, str] = {}


def _make_jwt_backend(sub: str, jti: str) -> str:
    def b64(d: dict) -> str:
        return base64.urlsafe_b64encode(
            json.dumps(d, separators=(",", ":")).encode()
        ).rstrip(b"=").decode()
    header  = b64({"alg": "none", "typ": "JWT"})
    payload = b64({"sub": sub, "jti": jti, "exp": 9999999999,
                   "preferred_username": sub})
    return f"{header}.{payload}."


@app.get("/api/v1/auth/config")
async def auth_config() -> JSONResponse:
    # enabled=true activates the auth flow in AuthContext.
    # No keycloak_url — AuthContext detects our custom flow via absence of it.
    return JSONResponse({
        "enabled": True,
        "token_broker_enabled": True,
    })


@app.post("/api/v1/auth/login")
async def auth_login(request: Request) -> JSONResponse:
    """Simulate IdP: generate a one-time code and return the callback URL."""
    body = await request.json()
    redirect_uri = body.get("redirect_uri", "http://localhost:3000/auth/callback")
    code = str(uuid.uuid4())
    jti  = str(uuid.uuid4())
    _pending_codes[code] = jti
    # Return the callback URL as if the IdP redirected back.
    sep = "&" if "?" in redirect_uri else "?"
    return JSONResponse({"url": f"{redirect_uri}{sep}code={code}"})


@app.get("/api/v1/auth/token")
async def auth_token(code: str) -> JSONResponse:
    """Exchange one-time code for a JWT — consume and discard the code."""
    jti = _pending_codes.pop(code, None)
    if not jti:
        return JSONResponse({"detail": "Invalid or expired code"}, status_code=400)
    token = _make_jwt_backend(sub="user", jti=jti)
    return JSONResponse({"access_token": token, "token_type": "Bearer"})


# ── Agent discovery ───────────────────────────────────────────────────────────

@app.get("/api/v1/namespaces")
async def list_namespaces() -> JSONResponse:
    # Single fixed namespace under compose.
    return JSONResponse({"namespaces": ["compose"]})


@app.get("/api/v1/agents")
async def list_agents(namespace: str = "compose") -> JSONResponse:
    agents = _load_agents()
    # Fetch all cards concurrently — one GET per agent, cached after first call.
    cards = await asyncio.gather(*[_fetch_agent_card(a["url"]) for a in agents])
    items = [
        {
            "name": a["name"],
            "namespace": "compose",
            "description": a.get("description", ""),
            "status": "Ready",
            "labels": {},
            "workloadType": "agent",
            "createdAt": "",
            "tags": _card_tags(card),
            "examples": _card_examples(card),
            "security": _card_security(card),
        }
        for a, card in zip(agents, cards)
    ]
    return JSONResponse({"items": items})


# ── Chat proxy ────────────────────────────────────────────────────────────────

def _agent_url(name: str) -> str | None:
    for a in _load_agents():
        if a["name"] == name:
            return a["url"].rstrip("/")
    return None


# ── Async chat tasks ──────────────────────────────────────────────────────────
# The BFF submits the agent call as a background task and returns a task_id
# immediately. The frontend LONG-POLLS GET /chat/result/{task_id}, which blocks
# on the task's asyncio.Event until the result is ready — no polling interval.
#
# Redirect-safe: the result + Event live in _tasks, independent of any
# /chat/result request. If the browser does a full-page OAuth redirect, the
# aborted long-poll doesn't touch the task; the background agent call keeps
# running. On return, the reconnected long-poll returns an already-stored
# result immediately (Event already set) or blocks until it's ready.
#
# Each entry: {status, done: asyncio.Event, _task: Task, content?, session_id?, detail?}
# In-memory store; lost on BFF restart (frontend poll then gets 404 → retry).
_tasks: dict[str, dict] = {}


def _finish_task(task_id: str, result: dict) -> None:
    """Store a task's terminal result and wake any waiting long-poll.
    Preserves the entry's Event/handle by updating fields in place."""
    entry = _tasks.get(task_id)
    if entry is None:
        return
    entry.update(result)
    done: asyncio.Event = entry["done"]
    done.set()


def _extract_content(result: dict) -> str:
    """Extract the agent's reply text from an A2A Task response."""
    if result.get("artifacts"):
        return "\n".join(
            p["text"]
            for a in result["artifacts"]
            for p in (a.get("parts") or [])
            if p.get("kind") == "text"
        )
    if result.get("status", {}).get("message", {}).get("parts"):
        return "\n".join(
            p["text"]
            for p in result["status"]["message"]["parts"]
            if p.get("kind") == "text"
        )
    return ""


async def _run_agent_task(task_id: str, url: str, message: str,
                          session_id: str, auth: str) -> None:
    """Background task: perform the blocking agent call and store the result."""
    rpc_body = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "message/send",
        "params": {
            "message": {
                "role": "user",
                "messageId": str(uuid.uuid4()),
                "parts": [{"kind": "text", "text": message}],
                **({"contextId": session_id} if session_id else {}),
            }
        },
    }
    log.info("task %s: calling agent %s", task_id, url)
    try:
        # No read timeout — the agent call blocks as long as it needs (it may
        # wait on HITL auth). Cancellation (chat/cancel, new-session) is how a
        # stuck task is torn down, not a timer.
        async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=10.0)) as client:
            resp = await client.post(
                url, json=rpc_body,
                headers={"Authorization": auth} if auth else {},
            )
        if not resp.is_success:
            log.warning("task %s: agent returned %s", task_id, resp.status_code)
            _finish_task(task_id, {"status": "error", "detail": resp.text})
            return
        result = resp.json().get("result", {})
        content = _extract_content(result) or json.dumps(result)
        _finish_task(task_id, {
            "status": "done",
            "content": content,
            "session_id": result.get("contextId") or session_id or "",
        })
        log.info("task %s: done (%d chars)", task_id, len(content))
    except asyncio.CancelledError:
        # Task was cancelled (mid-task abort). Closing this coroutine closes the
        # httpx connection to the agent, which — if the agent honors client
        # disconnect — cancels the agent's in-flight MCP/token acquisition too.
        log.info("task %s: cancelled", task_id)
        _finish_task(task_id, {"status": "error", "detail": "cancelled"})
        raise
    except Exception as exc:
        log.error("task %s: failed: %s", task_id, exc)
        _finish_task(task_id, {"status": "error", "detail": str(exc)})


@app.post("/api/v1/chat/{namespace}/{name}/send")
async def chat(namespace: str, name: str, request: Request) -> JSONResponse:
    url = _agent_url(name)
    if not url:
        return JSONResponse({"detail": f"Agent '{name}' not found"}, status_code=404)

    auth = request.headers.get("authorization", "")
    body = await request.json()
    message = body.get("message", "")
    session_id = body.get("session_id") or ""

    task_id = str(uuid.uuid4())
    # Tag the task with the JWT (jti) it belongs to, so _cleanup can cancel
    # exactly this session's in-flight tasks when the session is torn down.
    jwt = auth[7:] if auth.startswith("Bearer ") else ""
    # 'done' Event is set when the result is stored — /chat/result blocks on it.
    _tasks[task_id] = {"status": "pending", "done": asyncio.Event(), "jti": jwt}
    log.info("chat: submitted task %s to agent '%s' [session %s]",
             task_id, name, _tag(jwt))

    # Fire-and-forget: the blocking agent call runs here, in the BFF.
    # Keep the task handle so /chat/cancel can cancel it (Option 1) — cancelling
    # closes the BFF→agent connection without touching the token-broker session.
    task = asyncio.create_task(_run_agent_task(
        task_id, url, message, session_id, auth,
    ))
    _tasks[task_id]["_task"] = task

    return JSONResponse({"task_id": task_id}, status_code=202)


@app.post("/api/v1/chat/cancel/{task_id}")
async def chat_cancel(task_id: str) -> JSONResponse:
    """Option 1 cancel: cancel the BFF→agent asyncio task, closing the agent
    connection. Does NOT touch the token-broker session (that survives for the
    browser; use POST /token-broker/new-session to reset it explicitly)."""
    task = _tasks.get(task_id)
    if task and task.get("_task") and not task["_task"].done():
        task["_task"].cancel()
        log.info("chat: cancelled task %s", task_id)
    return JSONResponse({"status": "cancelled"}, status_code=200)


# How long a finished result stays fetchable after its FIRST successful read,
# before it self-evicts. The OAuth full-page-redirect flow inherently reads a
# task twice: once from the pre-redirect page (whose render is thrown away when
# the page unloads) and once from the resumed page after /oauth-resume. A
# pop-on-first-read store gives the second reader a 404 and the answer is lost.
# Keeping the result for a grace window lets the resumed page fetch the SAME
# result and render it. The window is short so the store stays bounded.
_RESULT_GRACE_SECONDS = 120


async def _evict_task_later(task_id: str) -> None:
    try:
        await asyncio.sleep(_RESULT_GRACE_SECONDS)
    except asyncio.CancelledError:
        return
    _tasks.pop(task_id, None)


@app.get("/api/v1/chat/result/{task_id}")
async def chat_result(task_id: str) -> JSONResponse:
    """Long-poll — blocks on the task's 'done' Event until the result is ready.

    Redirect-safe AND resume-safe: if the browser did a full-page OAuth
    redirect, the aborted pre-redirect poll may have already read (and would,
    under pop-on-read, have consumed) the result. Instead of popping on first
    read, we schedule a delayed eviction, so the result stays fetchable for a
    grace window. Repeated reads within that window (e.g. the doomed pre-redirect
    poll AND the resumed page's poll) all return the SAME result — the resumed
    page renders it. The entry self-evicts after the window to bound the store."""
    task = _tasks.get(task_id)
    if task is None:
        # Unknown task (BFF restarted, evicted after grace, or bad id) — stop.
        return JSONResponse({"status": "unknown"}, status_code=404)

    # Block until the task finishes (Event already set → returns immediately).
    await task["done"].wait()

    # Schedule eviction ONCE (idempotent): the first reader to reach here starts
    # the grace timer; later reads within the window reuse the stored result and
    # do not restart or cancel the timer.
    if not task.get("_evicting"):
        task["_evicting"] = True
        asyncio.create_task(_evict_task_later(task_id))

    if task["status"] == "done":
        return JSONResponse({
            "status": "done",
            "content": task["content"],
            "session_id": task.get("session_id", ""),
        })
    return JSONResponse({"status": "error", "detail": task.get("detail", "")})


# ── Token-broker session ──────────────────────────────────────────────────────

@app.post("/api/v1/token-broker/session")
async def create_session(request: Request) -> JSONResponse:
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return JSONResponse({"detail": "Unauthorized"}, status_code=401)
    jwt = auth[7:]

    body = await request.json()
    redirect_url = body.get("redirect_url", REDIRECT_URL)

    ok = await _open_session(jwt, redirect_url)
    if not ok:
        return JSONResponse({"detail": "Token Broker unavailable"}, status_code=503)
    return JSONResponse({}, status_code=201)


@app.get("/api/v1/token-broker/ui-events")
async def ui_events(request: Request) -> JSONResponse:
    """Long-poll — blocks on the current session's queue until an event.

    No timer. Captures the queue at call time and blocks until an event
    arrives. If the session is cleaned up while blocked, _cleanup() pushes a
    session_ended sentinel into that queue, waking this handler so it returns
    and the frontend reconnects to the new session's queue."""
    tag = _tag(_jwt)
    queue = _event_queue
    if queue is None:
        log.info("[session %s] /ui-events: NO SESSION → 404", tag)
        return JSONResponse({"detail": "No active session"}, status_code=404)
    event = await queue.get()
    log.info("[session %s] /ui-events: delivered %s", tag, event.get("type", "unknown"))
    return JSONResponse(event)


@app.delete("/api/v1/token-broker/session")
async def end_session(request: Request) -> JSONResponse:
    # _cleanup() ends the broker session AND cancels in-flight tasks — total
    # teardown, no leftovers in the BFF or at the broker.
    await _cleanup()
    return JSONResponse({}, status_code=200)


@app.post("/api/v1/token-broker/new-session")
async def new_session(request: Request) -> JSONResponse:
    """User-driven session reset. _open_session() calls _cleanup() first, which
    is the single total-teardown choke point: it cancels in-flight agent tasks
    (freeing the agent) and ends the old broker session (closing session.Done,
    which unblocks any stuck AcquireToken). After that a fresh session opens
    with the same JWT, guaranteeing NO leftovers of the previous session in the
    BFF or at the token broker."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return JSONResponse({"detail": "Unauthorized"}, status_code=401)
    jwt = auth[7:]

    # Force a full teardown first (do NOT hit _open_session's reuse path — a
    # reset with the same JWT must still tear down + recreate, not reuse).
    await _cleanup()
    ok = await _open_session(jwt, REDIRECT_URL)
    if not ok:
        return JSONResponse({"detail": "Token Broker unavailable"}, status_code=503)
    log.info("token-broker: session reset by user")
    return JSONResponse({}, status_code=201)
