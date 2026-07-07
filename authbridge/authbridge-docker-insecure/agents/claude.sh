# claude agent — drives the Claude Code CLI headlessly. Uses ANTHROPIC_* (not
# LLM_*); no MCP tool (reaches the model over HTTPS via the sidecar forward
# proxy). Bind-mounts ${HOME}/mounts/claude into /workspace (rw).
# Host ports: 9002 (reverse proxy), 9097 (stats), 9098 (session API).
#
# Create the host mount dir before first run:  mkdir -p ~/mounts/claude
unit_name claude
phase 40

AGENT_ID="claude-agent"
AGENT_DESCRIPTION="General-purpose agent driving the Claude Code CLI"

# Pre-built agent image from the agent-examples repo.
# Override CLAUDE_AGENT_IMAGE to pin a tag or point at a local build.
run_container --name agent-claude \
  --image "${CLAUDE_AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/claude_agent:latest}" \
  --env PORT=8000 \
  --env HOST=0.0.0.0 \
  --env-pass ANTHROPIC_AUTH_TOKEN \
  --env "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}" \
  --env "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-sonnet}" \
  --env "ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL:-haiku}" \
  --env HTTP_PROXY=http://authbridge-claude:8081 \
  --env http_proxy=http://authbridge-claude:8081 \
  --env HTTPS_PROXY=http://authbridge-claude:8081 \
  --env https_proxy=http://authbridge-claude:8081 \
  --mount "${HOME}/mounts/claude:/workspace:rw"

run_container --name authbridge-claude \
  --image ghcr.io/kagenti/kagenti-extensions/authbridge:latest \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_NAME=agent-claude \
  --env AGENT_PORT=8000 \
  --env "LOG_LEVEL=${LOG_LEVEL:-info}" \
  --mount "${STACK_ROOT}/authbridge-config.yaml:/etc/authbridge/config.yaml:ro" \
  --volume broker_routes:/etc/authproxy:ro \
  --port 9002:8080 --port 9097:9093 --port 9098:9094 \
  --needs-started agent-claude \
  --needs-completed broker-routes-assemble \
  --cmd -- --config /etc/authbridge/config.yaml

oneshot --name registrar-claude --image busybox \
  --volume registry:/registry \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_ENDPOINT=http://authbridge-claude:8080 \
  --cmd -- sh -c 'printf "{\"name\":\"%s\",\"description\":\"%s\",\"url\":\"%s\"}" "$AGENT_ID" "$AGENT_DESCRIPTION" "$AGENT_ENDPOINT" > /registry/claude.json'
