# rossocortex-backend — the UI's BFF (API proxy, agent discovery, token-broker
# bridge). Built from ./rossocortex-ui/backend.
#
# Phase 50 (UI). Depends on token-broker being up. Discovers agents by scanning
# the shared `registry` volume (each agent's registrar writes its descriptor
# there), so agents appear without a backend restart. No published port — the
# frontend nginx proxies /api/ to it over the shared network.
unit_name rossocortex-backend
phase 50

build_and_run --name rossocortex-backend \
  --context "${STACK_ROOT}/rossocortex-ui/backend" \
  --env ENV=local \
  --env TOKEN_BROKER_URL=http://token-broker:8190 \
  --env DEMO_REDIRECT_URL=http://localhost:3000/oauth-resume \
  --env AGENTS_REGISTRY_DIR=/registry \
  --volume registry:/registry:ro \
  --needs-started token-broker
