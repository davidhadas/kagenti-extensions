# github-mcp tool — official GitHub MCP server + its broker-route fragment.
#
# Phase 20: the server and its route registrar run before broker-routes-assemble
# (phase 30). This is an OAuth tool, so besides this file it also needs its
# scopes in RESOURCE_CONFIG in services/token-broker.sh (the one shared edit for
# OAuth tools).
#
# To add another OAuth tool: copy this file, rename the two containers, point the
# server at the right image/port, change the route fragment host + endpoints, and
# add the tool's scopes to services/token-broker.sh RESOURCE_CONFIG.
unit_name github-mcp
phase 20

run_container --name github-mcp \
  --image ghcr.io/github/github-mcp-server:v1.1.2 \
  --port 8082:8082 \
  --env-pass GITHUB_OAUTH_CLIENT_ID --env-pass GITHUB_OAUTH_CLIENT_SECRET \
  --cmd -- http --port=8082 --base-url=http://localhost:8082 --toolsets=default

# Route-fragment registrar: writes this tool's broker-route into the shared
# broker_routes volume. broker-routes-assemble (phase 30) concatenates all
# *.frag.yaml into broker-routes.yaml. The heredoc is written literally.
oneshot --name registrar-tool-github-mcp --image busybox \
  --volume broker_routes:/routes \
  --cmd -- sh -c 'cat > /routes/github-mcp.frag.yaml <<EOF
- host: "github-mcp"
  action: broker
  authorization_endpoint: "https://github.com/login/oauth/authorize"
  token_endpoint: "https://github.com/login/oauth/access_token"
EOF'
