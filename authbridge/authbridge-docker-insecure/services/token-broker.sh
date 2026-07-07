# token-broker service — HITL OAuth broker.
#
# Phase 10 (infra, no deps). Long-running, built from the kagenti-operator
# source tree (${CODE_DIR}/kagenti-operator/token-broker).
#
# RESOURCE_CONFIG is the ONE central touch-point for OAuth tools: when you add an
# OAuth tool (e.g. another github-mcp-style tool), add its scopes + endpoints
# here keyed by the tool's in-network URL. Passthrough tools need no entry.
unit_name token-broker
phase 10

build_and_run --name token-broker \
  --context "${CODE_DIR:-/Users/davidhadas/Code}/kagenti-operator/token-broker" \
  --port 8190:8190 \
  --env TOKEN_BROKER_PORT=8190 \
  --env-pass GITHUB_OAUTH_CLIENT_ID --env-pass GITHUB_OAUTH_CLIENT_SECRET \
  --env "OAUTH_CLIENT_ID=${GITHUB_OAUTH_CLIENT_ID:-}" \
  --env "OAUTH_CLIENT_SECRET=${GITHUB_OAUTH_CLIENT_SECRET:-}" \
  --env "OAUTH_CALLBACK_URL=${OAUTH_CALLBACK_URL:-http://localhost:8190/oauth/callback}" \
  --env ALLOWED_REDIRECT_HOSTS=localhost \
  --env OAUTH_AUTHORIZATION_ENDPOINT=https://github.com/login/oauth/authorize \
  --env OAUTH_TOKEN_ENDPOINT=https://github.com/login/oauth/access_token \
  --env TOKEN_BROKER_SESSION_TIMEOUT=600s \
  --env 'RESOURCE_CONFIG={"http://github-mcp:8082":{"scopes":["repo","read:org","read:user"],"authorization_endpoint":"https://github.com/login/oauth/authorize","token_endpoint":"https://github.com/login/oauth/access_token"}}'
