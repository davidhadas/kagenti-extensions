# bundle-server service — OPA policy bundle server.
#
# Phase 10 (infra, no deps). Built from the in-tree ./bundle-server context;
# serves the starter inbound/outbound policies from bundle-server/policies/,
# mounted read-only. Edit those .rego files to change policy, then restart.
unit_name bundle-server
phase 10

build_and_run --name bundle-server \
  --context "${STACK_ROOT}/bundle-server" \
  --port 8090:8090 \
  --env POLICY_DIR=/policies \
  --env LISTEN_ADDR=:8090 \
  --mount "${STACK_ROOT}/bundle-server/policies:/policies:ro"
