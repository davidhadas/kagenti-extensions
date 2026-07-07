#!/usr/bin/env sh
# run.sh — compose-free launcher for the AuthBridge insecure demo stack.
#
# Runs the whole stack (AuthBridge sidecars + plugins + services + tools + demo
# agents) on plain `docker` OR `podman` — no docker-compose, no podman-compose.
#
# Units are declared one-per-file under services/, agents/, tools/. This script
# is NEVER edited to add or remove a unit — drop a *.sh descriptor in the right
# directory (or delete one) and re-run. See README.md.
#
# Usage:
#   ./run.sh up [--build] [name...]   bring the stack up (optionally forcing rebuild)
#   ./run.sh down [--volumes]         remove all stack containers (and volumes)
#   ./run.sh ps                       list stack containers
#   ./run.sh logs [name] [-f]         logs for one container, or all stack containers
#   ./run.sh build [name...]          (re)build all build-context images
#
# Runtime selection: auto-detects `podman` then `docker`; override with RUNTIME=.
set -eu

cd "$(dirname "$0")"
STACK_ROOT="$PWD"
STACK_LABEL="authbridge-demo"
NET="authbridge-shared"
export STACK_ROOT STACK_LABEL NET

# ── runtime detection (podman or docker; RUNTIME= overrides) ──────────────────
detect_runtime() {
  if [ -n "${RUNTIME:-}" ]; then RT="$RUNTIME"; return; fi
  if command -v podman >/dev/null 2>&1; then RT="podman"
  elif command -v docker >/dev/null 2>&1; then RT="docker"
  else
    echo "run: neither podman nor docker found on PATH" >&2; exit 1
  fi
}

# SELinux relabel suffix for bind mounts: only needed on podman + Linux.
detect_selinux_suffix() {
  SELINUX_SUFFIX=""
  if [ "$RT" = podman ] && [ "$(uname -s)" = Linux ]; then
    SELINUX_SUFFIX=",z"
  fi
}

load_env() {
  if [ ! -f .env ]; then
    echo "run: .env not found. Copy .env.example to .env and fill it in:" >&2
    echo "     cp .env.example .env" >&2
    exit 1
  fi
  set -a; . ./.env; set +a
}

ensure_network_volumes() {
  $RT network create "$NET" >/dev/null 2>&1 || true
  # Pre-create named volumes so the first container that mounts them never races
  # a not-yet-created volume (the class of failure the old podman shim guarded).
  $RT volume create registry >/dev/null 2>&1 || true
  $RT volume create broker_routes >/dev/null 2>&1 || true
}

# Set up the spec collection area used by lib/helpers.sh.
init_specs() {
  SPEC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/authbridge-run.XXXXXX")"
  SPEC_INDEX="$SPEC_DIR/index"
  SPEC_SEQ="$SPEC_DIR/seq"
  : > "$SPEC_INDEX"; echo 0 > "$SPEC_SEQ"
  export SPEC_DIR SPEC_INDEX SPEC_SEQ RT SELINUX_SUFFIX
  # shellcheck disable=SC2064
  trap "rm -rf '$SPEC_DIR'" EXIT INT TERM
}

# Discover every unit by sourcing each descriptor. Each descriptor's helper
# calls append container specs to $SPEC_INDEX (keyed by phase). The glob IS the
# unit list — adding a file adds a unit, no edit here.
discover_units() {
  . ./lib/helpers.sh
  for f in services/*.sh agents/*.sh tools/*.sh; do
    [ -f "$f" ] || continue
    CUR_PHASE=50; CUR_UNIT=""
    # shellcheck disable=SC1090
    . "./$f"
  done
}

# Execute every collected spec in ascending phase order. __exec_spec (from
# helpers.sh) honors --needs-started / --needs-completed edges per container.
run_all() {
  # Stable sort: primary key phase (numeric), secondary key the spec path
  # (which is sequence-numbered, preserving in-file declaration order).
  # Materialize to a file first so the loop runs in THIS shell (not a pipe
  # subshell) and a failure can abort the whole launcher.
  sort -n -k1,1 -k2,2 "$SPEC_INDEX" | cut -f2 > "$SPEC_DIR/ordered"
  while IFS= read -r spec; do
    __exec_spec "$spec" || {
      echo "run: aborting — a unit failed to start (see above)" >&2
      exit 1
    }
  done < "$SPEC_DIR/ordered"
}

print_endpoints() {
  cat <<EOF

Stack is up. Endpoints:
  UI (RossoCortex)      http://localhost:3000
  token-broker          http://localhost:8190
  bundle-server         http://localhost:8090
  github-mcp            http://localhost:8082
  weather-tool-mcp      http://localhost:8083
  authbridge git-issue  http://localhost:9000  (stats :9093, session :9094)
  authbridge weather    http://localhost:9001  (stats :9095, session :9096)
  authbridge claude     http://localhost:9002  (stats :9097, session :9098)

  ./run.sh ps            list containers
  ./run.sh logs <name>   view a container's logs
  ./run.sh down          tear the stack down
EOF
}

# ── subcommands ───────────────────────────────────────────────────────────────

cmd_up() {
  DO_BUILD=0
  for a in "$@"; do [ "$a" = "--build" ] && DO_BUILD=1; done
  export DO_BUILD
  load_env
  ensure_network_volumes
  init_specs
  discover_units
  echo "Bringing up the AuthBridge demo stack with '$RT'..."
  run_all
  print_endpoints
}

cmd_build() {
  DO_BUILD=1; export DO_BUILD
  load_env
  init_specs
  discover_units
  # Build every build-context spec, ignore run/oneshot specs.
  . ./lib/helpers.sh
  cut -f2 "$SPEC_INDEX" | while IFS= read -r spec; do
    [ "$(sed -n 's/^KIND=//p' "$spec")" = build ] || continue
    name=$(sed -n 's/^NAME=//p' "$spec")
    context=$(sed -n 's/^CONTEXT=//p' "$spec")
    echo "  build $name  <-  $context"
    $RT build --label "$STACK_LABEL" -t "${name}:local" "$context"
  done
}

cmd_down() {
  rm_vols=0
  for a in "$@"; do [ "$a" = "--volumes" ] && rm_vols=1; done
  ids=$($RT ps -aq --filter "label=$STACK_LABEL" 2>/dev/null || true)
  if [ -n "$ids" ]; then
    echo "Removing stack containers..."
    # shellcheck disable=SC2086
    $RT rm -f $ids >/dev/null
  else
    echo "No stack containers found."
  fi
  $RT network rm "$NET" >/dev/null 2>&1 || true
  if [ "$rm_vols" = 1 ]; then
    echo "Removing named volumes (registry, broker_routes)..."
    $RT volume rm registry broker_routes >/dev/null 2>&1 || true
  fi
}

cmd_ps() {
  $RT ps -a --filter "label=$STACK_LABEL"
}

cmd_logs() {
  # ./run.sh logs [name] [-f]
  follow=""; target=""
  for a in "$@"; do
    case "$a" in
      -f|--follow) follow="-f" ;;
      *) target="$a" ;;
    esac
  done
  if [ -n "$target" ]; then
    $RT logs $follow "$target"
  else
    for c in $($RT ps -a --filter "label=$STACK_LABEL" --format '{{.Names}}'); do
      echo "==== $c ===="
      $RT logs "$c" 2>&1 | tail -n 20
    done
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────
detect_runtime
detect_selinux_suffix

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  up)    cmd_up "$@" ;;
  down)  cmd_down "$@" ;;
  ps)    cmd_ps "$@" ;;
  logs)  cmd_logs "$@" ;;
  build) cmd_build "$@" ;;
  ""|-h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    echo "run: unknown subcommand '$sub' (try: up, down, ps, logs, build)" >&2
    exit 2 ;;
esac
