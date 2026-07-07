# rossocortex-frontend — the React SPA served by nginx. Built from
# ./rossocortex-ui/frontend. Publishes the UI on :3000.
#
# Phase 50 (UI). Depends on the backend being up (nginx proxies /api/ to it).
unit_name rossocortex-frontend
phase 50

build_and_run --name rossocortex-frontend \
  --context "${STACK_ROOT}/rossocortex-ui/frontend" \
  --port 3000:3000 \
  --needs-started rossocortex-backend
