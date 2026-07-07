#!/usr/bin/env sh
# podman-compose compatibility shim for the `include:` list.
#
# docker-compose.yaml uses the Compose Spec top-level `include:` element to pull
# in one file per agent. Docker Compose (v2.20+) expands `include:` natively, so
# Docker users just run:  docker compose up --build
#
# podman-compose (as of 1.0.6) SILENTLY IGNORES `include:` — the agent services
# never get created. This script keeps docker-compose.yaml as the single source
# of truth: it reads the same `include:` list and replays each entry as a `-f`
# flag, which podman-compose DOES support and merges correctly.
#
# Usage (any compose subcommand + args):
#   ./podman-up.sh up --build
#   ./podman-up.sh down
#   ./podman-up.sh config
#   ./podman-up.sh logs -f authbridge-git-issue
#
# Set COMPOSE=docker to force the docker CLI instead of auto-detecting podman.
#
set -eu
cd "$(dirname "$0")"

# podman-compose derives the compose PROJECT name from the working-directory
# basename. Everything that filters by project (the Created-state recovery, the
# volume pre-create/remove) must use THIS value — hardcoding it drifts the
# moment the directory is renamed or copied (which is exactly how this stack was
# created). Deriving it keeps the recovery correct for any copy of the tree.
PROJECT="$(basename "$PWD")"

# Per-agent files anchor their shared-config bind mounts on ${COMPOSE_ROOT}.
# We run from the compose root here, and podman-compose resolves relative
# volume sources against the CWD (not per-file), so "." is correct. (Native
# docker `include:` instead resolves against the agent file's dir and uses the
# ".." default baked into the agent files.)
export COMPOSE_ROOT="."

ROOT="docker-compose.yaml"

# Extract the paths listed under the top-level `include:` block. We scan from
# the `include:` line until the next top-level key (a line starting in column 0)
# and pick up YAML list items (`  - path`), stripping any trailing comment.
AGENTS=$(awk '
  /^include:/                          { inc = 1; next }
  inc && /^[^[:space:]#]/              { inc = 0 }
  inc && /^[[:space:]]*-[[:space:]]/ {
    sub(/^[[:space:]]*-[[:space:]]*/, "")   # drop the "  - " prefix
    sub(/[[:space:]]*#.*/, "")               # drop trailing comment
    sub(/[[:space:]]+$/, "")                 # drop trailing whitespace
    if (length($0) > 0) print
  }
' "$ROOT")

if [ -z "$AGENTS" ]; then
  echo "podman-up.sh: no agents found under 'include:' in $ROOT" >&2
  echo "  (add lines like '  - agents/<name>.yaml' to the include: block)" >&2
  exit 1
fi

FILES="-f $ROOT"
for a in $AGENTS; do
  if [ ! -f "$a" ]; then
    echo "podman-up.sh: include entry '$a' not found" >&2
    exit 1
  fi
  FILES="$FILES -f $a"
done

# Capture the user's compose subcommand + args (e.g. "up --build") before we
# reuse the positional params to hold the compose runner.
USER_ARGS="$*"

# Pick the compose runner. Honor an explicit COMPOSE override
# (COMPOSE="docker compose" or COMPOSE="podman-compose"); otherwise prefer
# `podman compose`, then `podman-compose`, then `docker compose`.
if [ -n "${COMPOSE:-}" ]; then
  RUNNER="$COMPOSE"
elif command -v podman >/dev/null 2>&1; then
  RUNNER="podman compose"
elif command -v podman-compose >/dev/null 2>&1; then
  RUNNER="podman-compose"
else
  RUNNER="docker compose"
fi

# podman-compose can race on FIRST creation of a named volume (mount before
# create → "no such volume"). Pre-create the shared volumes on `up` so first run
# is clean. Idempotent; ignored if podman isn't the runner.
#
# On `down`, also remove the named volumes so that stale volume mountpoints
# (left behind by podman VM upgrades) never survive across restarts and cause
# "internal libpod error" on the next `up`.
case "$USER_ARGS" in
  *up*)
    if command -v podman >/dev/null 2>&1; then
      for v in registry broker_routes; do
        podman volume create "${PROJECT}_$v" >/dev/null 2>&1 || true
      done
    fi
    ;;
  *down*)
    if command -v podman >/dev/null 2>&1; then
      for v in registry broker_routes; do
        podman volume rm "${PROJECT}_$v" >/dev/null 2>&1 || true
      done
    fi
    ;;
esac

echo "+ $RUNNER $FILES $USER_ARGS" >&2
# shellcheck disable=SC2086  # RUNNER/FILES/USER_ARGS intentionally word-split

case "$USER_ARGS" in
  *up*)
    # ─────────────────────────────────────────────────────────────────────────
    # HEADS-UP: podman-compose has a known attach-race on `up -d`. For one or
    # more containers whose dependency finished just as the attach window opened,
    # it prints lines like:
    #
    #     Error: unable to start container "<id>": starting some containers: internal libpod error
    #     Error: executing .../podman-compose ... up ... : exit status 125
    #
    # These are NOT real failures — the containers were created correctly and
    # just need starting. This wrapper starts any such "Created" containers right
    # after compose returns, then verifies the whole stack is up. So if you see
    # "Error: unable to start container ..." above the final summary below, it is
    # a benign podman-compose bug and can be IGNORED — trust the summary.
    # ─────────────────────────────────────────────────────────────────────────

    # Run compose (ignore its exit code — the attach-race exits 125 even on a
    # recoverable run). Its output, including any benign errors above, streams
    # to the terminal as usual.
    $RUNNER $FILES "$@" || true

    # Recovery: start anything the attach-race left in "Created". On a cold or
    # loaded machine several sidecars can be Created at once and a single
    # `podman start` may not have transitioned them to "running" by the time we
    # check — so RETRY across a few passes, re-listing Created each pass and
    # giving them a moment to come up, before the health verdict. This prevents
    # a false "NOT healthy" when the containers are merely slow to start.
    if command -v podman >/dev/null 2>&1; then
      _pass=1
      while [ "$_pass" -le 6 ]; do
        CREATED=$(podman ps -a \
          --filter "label=io.podman.compose.project=${PROJECT}" \
          --filter "status=created" --format "{{.Names}}" 2>/dev/null || true)
        [ -z "$CREATED" ] && break
        [ "$_pass" = 1 ] && echo "podman-up.sh: starting containers left in Created state:" >&2
        for c in $CREATED; do
          echo "  podman start $c (pass $_pass)" >&2
          podman start "$c" >/dev/null 2>&1 || true
        done
        sleep 2
        _pass=$(( _pass + 1 ))
      done

      # Final health check. We do NOT assert a fixed service count — agents,
      # tools and services are added/removed freely, so the healthy number
      # varies. Health is instead the ABSENCE of trouble: nothing left in
      # "Created" (the attach-race outcome) and nothing that exited non-zero.
      # This is count-agnostic and stays correct as the stack grows or shrinks.
      STILL_CREATED=$(podman ps -a \
        --filter "label=io.podman.compose.project=${PROJECT}" \
        --filter "status=created" --format "{{.Names}}" 2>/dev/null || true)
      # Exited with a non-zero code = a container that actually failed. (Our
      # one-shot registrars / broker-routes-assemble exit 0 on success — those
      # are expected and are NOT flagged.)
      FAILED_EXIT=$(podman ps -a \
        --filter "label=io.podman.compose.project=${PROJECT}" \
        --format '{{.Names}} {{.Status}}' 2>/dev/null \
        | awk '/Exited \([1-9]/ {print $1}' || true)
      DOWN=$(printf '%s\n%s\n' "$STILL_CREATED" "$FAILED_EXIT" | sed '/^$/d' | sort -u)

      echo "" >&2
      if [ -z "$DOWN" ]; then
        echo "==============================================================" >&2
        echo " All good — every service is up." >&2
        echo " Any \"Error: unable to start container ...\" lines above are a" >&2
        echo " known podman-compose bug and can be safely IGNORED." >&2
        echo " Open the UI at http://localhost:3000" >&2
        echo "==============================================================" >&2
      else
        echo "==============================================================" >&2
        echo " Some containers are NOT healthy after recovery:" >&2
        for c in $DOWN; do echo "   - $c" >&2; done
        echo " This is a REAL problem — check: ./podman-up.sh logs <name>" >&2
        echo "==============================================================" >&2
      fi
    fi
    ;;
  *)
    exec $RUNNER $FILES "$@"
    ;;
esac
