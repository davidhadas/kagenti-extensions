# lib/helpers.sh — helper API sourced into every unit descriptor.
#
# Descriptors (services/*.sh, agents/*.sh, tools/*.sh) call these helpers to
# declare containers in runtime-neutral terms. The helpers NEVER execute a
# container directly — they serialize each declaration into a per-container spec
# file under $SPEC_DIR and append one "<phase>\t<specfile>" line to $SPEC_INDEX.
# run.sh then sorts by phase and executes each spec via __exec_spec.
#
# This indirection is what lets a descriptor be pure declaration: the same
# helper call works whether run.sh is collecting the unit table or (later)
# running it. Descriptors therefore never mention the runtime binary, the shared
# label, the network, --add-host, or SELinux relabeling — those live only here.
#
# Required environment (set by run.sh before sourcing any descriptor):
#   RT              container runtime binary ("podman" or "docker")
#   NET             shared network name
#   STACK_LABEL     label applied to every container (down/ps/logs filter on it)
#   SELINUX_SUFFIX  ",z" on podman+Linux bind mounts, "" otherwise
#   STACK_ROOT      absolute path of the stack dir (for bind-mount sources)
#   SPEC_DIR        temp dir for per-container spec files
#   SPEC_INDEX      temp file: one "<phase>\t<specfile>" line per container
#   CUR_PHASE       current unit's phase (set by phase(); default 50)
#   SPEC_SEQ        monotonically increasing counter (file) for spec filenames

# ── unit-level declarations ──────────────────────────────────────────────────

# unit_name NAME — human label for the unit (currently informational; grouping
# is by container name + label). Kept so descriptors read declaratively and so a
# future feature can group by unit without changing descriptors.
unit_name() {
  CUR_UNIT="$1"
}

# phase N — coarse ordering tier for every container declared after this call in
# the current descriptor. Lower runs first. Default 50 if never called.
phase() {
  CUR_PHASE="$1"
}

# ── the three container helpers ───────────────────────────────────────────────
# All three share one serializer (__emit_spec). KIND distinguishes them:
#   run      long-running, pulled image
#   build    long-running, built from --context
#   oneshot  run to completion; run.sh blocks on `$RT wait` and fails up on !=0
#
# Flags (order-free, repeatable where noted):
#   --name NAME             container name (required)
#   --image REF             pulled image           (run / oneshot)
#   --context DIR           build context          (build)
#   --port H:C              publish host:container (repeatable)
#   --env K=V               literal env            (repeatable)
#   --env-pass K            forward K from run.sh's process env (repeatable)
#   --mount SRC:DST[:ro]    bind mount (SELinux suffix auto-added) (repeatable)
#   --volume VOL:DST[:ro]   named-volume mount (no relabel)        (repeatable)
#   --cmd -- ARGS...        container command/args (consumes rest of line)
#   --needs-started NAME    wait until NAME is running before starting this
#   --needs-completed NAME  wait until NAME (a oneshot) exited 0 before starting
#   --after NAME            (oneshot) same as --needs-completed, reads intent-ward

run_container()  { __emit_spec run "$@"; }
build_and_run()  { __emit_spec build "$@"; }
oneshot()        { __emit_spec oneshot "$@"; }

# __emit_spec KIND <flags...> — serialize one container declaration to a spec
# file and index it by phase. Repeatable flags accumulate as newline-separated
# blocks inside the spec file; the --cmd tail is captured verbatim.
__emit_spec() {
  kind="$1"; shift

  # Allocate a spec file, sequence-numbered so index order is stable/sortable.
  seq=$(( $(cat "$SPEC_SEQ") + 1 )); echo "$seq" > "$SPEC_SEQ"
  spec="$SPEC_DIR/spec.$(printf '%04d' "$seq")"

  name=""; image=""; context=""
  : > "$spec"
  printf 'KIND=%s\n' "$kind" >> "$spec"

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)            name="$2"; printf 'NAME=%s\n' "$2" >> "$spec"; shift 2 ;;
      --image)           image="$2"; printf 'IMAGE=%s\n' "$2" >> "$spec"; shift 2 ;;
      --context)         context="$2"; printf 'CONTEXT=%s\n' "$2" >> "$spec"; shift 2 ;;
      --port)            printf 'PORT=%s\n' "$2" >> "$spec"; shift 2 ;;
      --env)             printf 'ENV=%s\n' "$2" >> "$spec"; shift 2 ;;
      --env-pass)        printf 'ENVPASS=%s\n' "$2" >> "$spec"; shift 2 ;;
      --mount)           printf 'MOUNT=%s\n' "$2" >> "$spec"; shift 2 ;;
      --volume)          printf 'VOLUME=%s\n' "$2" >> "$spec"; shift 2 ;;
      --needs-started)   printf 'NEEDSTARTED=%s\n' "$2" >> "$spec"; shift 2 ;;
      --needs-completed) printf 'NEEDCOMPLETED=%s\n' "$2" >> "$spec"; shift 2 ;;
      --after)           printf 'NEEDCOMPLETED=%s\n' "$2" >> "$spec"; shift 2 ;;
      --cmd)
        shift
        [ "$1" = "--" ] && shift
        # Remainder of the line is the container command. Store each arg on its
        # own CMD= line so args with spaces survive round-trip.
        while [ $# -gt 0 ]; do printf 'CMD=%s\n' "$1" >> "$spec"; shift; done
        ;;
      *)
        echo "helpers: $kind: unknown flag '$1' (name=${name:-?})" >&2
        exit 2 ;;
    esac
  done

  if [ -z "$name" ]; then
    echo "helpers: $kind: missing --name" >&2; exit 2
  fi
  printf 'PHASE=%s\n' "${CUR_PHASE:-50}" >> "$spec"
  printf '%s\t%s\n' "${CUR_PHASE:-50}" "$spec" >> "$SPEC_INDEX"
}

# ── standalone edge declarations (alternative to the flag forms) ──────────────
# These attach to the MOST RECENT container spec, so a descriptor may write
#   run_container ...
#   needs_started agent-foo
# as an equivalent to the --needs-started flag. Handy for readability.
needs_started() {
  spec=$(tail -n1 "$SPEC_INDEX" | cut -f2)
  [ -n "$spec" ] && printf 'NEEDSTARTED=%s\n' "$1" >> "$spec"
}
needs_completed() {
  spec=$(tail -n1 "$SPEC_INDEX" | cut -f2)
  [ -n "$spec" ] && printf 'NEEDCOMPLETED=%s\n' "$1" >> "$spec"
}

# ── execution (called by run.sh, one spec at a time, in phase order) ──────────

# __spec_get SPEC KEY — echo all values for KEY (one per line), order-preserving.
__spec_get() {
  sed -n "s/^$2=//p" "$1"
}

# __wait_running NAME [TIMEOUT] — poll until NAME is in "running" state.
__wait_running() {
  _n="$1"; _t="${2:-60}"; _i=0
  while [ "$_i" -lt "$_t" ]; do
    _st=$($RT inspect --format '{{.State.Running}}' "$_n" 2>/dev/null || echo "")
    [ "$_st" = "true" ] && return 0
    sleep 1; _i=$(( _i + 1 ))
  done
  echo "run: timed out waiting for '$_n' to be running" >&2
  return 1
}

# __wait_completed NAME — block until NAME exits; return its exit code. Uses
# `$RT wait`, falling back to inspecting .State.ExitCode if the container has
# already gone (dodges podman's create/wait race the old shim worked around).
__wait_completed() {
  _n="$1"
  _rc=$($RT wait "$_n" 2>/dev/null | tail -n1) || _rc=""
  case "$_rc" in
    ''|*[!0-9]*)
      # `wait` gave nothing usable (container already gone, or a non-numeric
      # line) — fall back to the recorded exit code.
      _rc=$($RT inspect --format '{{.State.ExitCode}}' "$_n" 2>/dev/null | tail -n1)
      ;;
  esac
  case "$_rc" in
    ''|*[!0-9]*) _rc=1 ;;
  esac
  return "$_rc"
}

# __exec_spec SPEC — build the $RT command from a spec file and run it. For
# oneshots, block on completion and fail (return 1) on non-zero exit.
__exec_spec() {
  spec="$1"
  kind=$(__spec_get "$spec" KIND);  name=$(__spec_get "$spec" NAME)
  image=$(__spec_get "$spec" IMAGE); context=$(__spec_get "$spec" CONTEXT)

  # Honor dependency edges before starting.
  for dep in $(__spec_get "$spec" NEEDCOMPLETED); do
    __wait_completed "$dep" || {
      echo "run: dependency '$dep' did not complete successfully (needed by $name)" >&2
      $RT logs "$dep" 2>&1 | tail -n 30 >&2 || true
      return 1
    }
  done
  for dep in $(__spec_get "$spec" NEEDSTARTED); do
    __wait_running "$dep" || return 1
  done

  # A build unit builds its image first (tag <name>:local).
  if [ "$kind" = build ]; then
    image="${name}:local"
    # Build when forced (--build) or when the image doesn't exist yet.
    # `image inspect` is common to docker AND podman (unlike `image exists`,
    # which is podman-only), so it's the portable existence check.
    _need_build=0
    [ "${DO_BUILD:-0}" = 1 ] && _need_build=1
    $RT image inspect "$image" >/dev/null 2>&1 || _need_build=1
    if [ "$_need_build" = 1 ]; then
      echo "  build $name  <-  $context"
      $RT build --label "$STACK_LABEL" -t "$image" "$context" >&2 || {
        echo "run: build failed for $name" >&2; return 1; }
    fi
  fi

  # Assemble the run argv. Common flags first.
  set -- run -d --name "$name" --label "$STACK_LABEL" --network "$NET" \
    --add-host host.docker.internal:host-gateway
  [ "$kind" = oneshot ] && set -- "$@" --restart no || set -- "$@" --restart unless-stopped

  # Publish ports.
  for p in $(__spec_get "$spec" PORT); do set -- "$@" --publish "$p"; done
  # Literal envs.
  __spec_get "$spec" ENV > "$SPEC_DIR/.envtmp"
  while IFS= read -r e; do [ -n "$e" ] && set -- "$@" --env "$e"; done < "$SPEC_DIR/.envtmp"
  # Pass-through envs (forward current value from run.sh's environment).
  for k in $(__spec_get "$spec" ENVPASS); do
    eval "_v=\${$k-}"
    set -- "$@" --env "$k=$_v"
  done
  # Bind mounts (SELinux relabel suffix on podman+Linux).
  __spec_get "$spec" MOUNT > "$SPEC_DIR/.mnttmp"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    set -- "$@" --volume "${m}${SELINUX_SUFFIX}"
  done < "$SPEC_DIR/.mnttmp"
  # Named-volume mounts (no relabel).
  for v in $(__spec_get "$spec" VOLUME); do set -- "$@" --volume "$v"; done

  set -- "$@" "$image"

  # Container command/args, if any (each CMD= line is one arg).
  __spec_get "$spec" CMD > "$SPEC_DIR/.cmdtmp"
  while IFS= read -r c; do set -- "$@" "$c"; done < "$SPEC_DIR/.cmdtmp"

  # (Re)create: remove any stale container of the same name first.
  $RT rm -f "$name" >/dev/null 2>&1 || true

  if [ "$kind" = oneshot ]; then
    echo "  oneshot $name"
    $RT "$@" >/dev/null || { echo "run: failed to start oneshot $name" >&2; return 1; }
    __wait_completed "$name" || {
      echo "run: oneshot '$name' exited non-zero" >&2
      $RT logs "$name" 2>&1 | tail -n 30 >&2 || true
      return 1
    }
  else
    echo "  run $name"
    $RT "$@" >/dev/null || { echo "run: failed to start $name" >&2; return 1; }
  fi
}
