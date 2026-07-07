# git-issue agent — three containers: the agent app, its AuthBridge sidecar, and
# a one-shot registrar that advertises it to the UI.
#
# To add an agent: copy this file, rename the three --name values
# (agent-<n>, authbridge-<n>, registrar-<n>), set AGENT_ID/AGENT_DESCRIPTION,
# the agent --image, the proxy host (authbridge-<n>:8081), MCP_URL, three FREE
# host ports (see the port map in README), and the registrar output filename.
# Nothing else to edit — ./run.sh discovers this file by glob.
unit_name git-issue
phase 40

AGENT_ID="git-issue-agent"
AGENT_DESCRIPTION="Answer queries about GitHub issues"

# (a) the agent application. Pre-built image from the agent-examples repo.
# Reaches tools ONLY via HTTP(S)_PROXY → its sidecar's forward proxy (:8081).
# Started before the sidecar. Override GIT_ISSUE_AGENT_IMAGE to pin a tag or
# point at a local build.
run_container --name agent-git-issue \
  --image "${GIT_ISSUE_AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/git_issue_agent:latest}" \
  --env PORT=8000 \
  --env-pass LLM_API_BASE \
  --env "LLM_API_KEY=${LLM_API_KEY:-ollama}" \
  --env "TASK_MODEL_ID=${TASK_MODEL_ID:-ollama_chat/ibm/granite4:latest}" \
  --env HTTP_PROXY=http://authbridge-git-issue:8081 \
  --env http_proxy=http://authbridge-git-issue:8081 \
  --env HTTPS_PROXY=http://authbridge-git-issue:8081 \
  --env https_proxy=http://authbridge-git-issue:8081 \
  --env MCP_URL=http://github-mcp:8082/mcp \
  --env MCP_TIMEOUT=600 \
  --env OTEL_SDK_DISABLED=true \
  --env CREWAI_TELEMETRY=false

# (b) the AuthBridge sidecar. The shared authbridge-config.yaml is mounted
# read-only; the image expands ${AGENT_NAME}/${AGENT_PORT}/${AGENT_ID} from these
# env vars, so the config is never templated. Reverse proxy :8080 → host :9000;
# stats :9093 → :9093; session API :9094 → :9094.
run_container --name authbridge-git-issue \
  --image ghcr.io/kagenti/kagenti-extensions/authbridge:latest \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_NAME=agent-git-issue \
  --env AGENT_PORT=8000 \
  --env "LOG_LEVEL=${LOG_LEVEL:-info}" \
  --mount "${STACK_ROOT}/authbridge-config.yaml:/etc/authbridge/config.yaml:ro" \
  --volume broker_routes:/etc/authproxy:ro \
  --port 9000:8080 --port 9093:9093 --port 9094:9094 \
  --needs-started agent-git-issue \
  --needs-completed broker-routes-assemble \
  --cmd -- --config /etc/authbridge/config.yaml

# (c) registrar one-shot — writes the UI descriptor into the shared registry.
oneshot --name registrar-git-issue --image busybox \
  --volume registry:/registry \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_ENDPOINT=http://authbridge-git-issue:8080 \
  --cmd -- sh -c 'printf "{\"name\":\"%s\",\"description\":\"%s\",\"url\":\"%s\"}" "$AGENT_ID" "$AGENT_DESCRIPTION" "$AGENT_ENDPOINT" > /registry/git-issue.json'
