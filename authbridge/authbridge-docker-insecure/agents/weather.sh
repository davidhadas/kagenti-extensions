# weather agent — agent app + AuthBridge sidecar + registrar. Calls the
# weather-tool-mcp passthrough tool (no OAuth). Same shape as git-issue.sh.
# Host ports: 9001 (reverse proxy), 9095 (stats), 9096 (session API).
unit_name weather
phase 40

AGENT_ID="weather-agent"
AGENT_DESCRIPTION="Answer questions about the weather in a city"

# Pre-built agent image from the agent-examples repo.
# Override WEATHER_AGENT_IMAGE to pin a tag or point at a local build.
run_container --name agent-weather \
  --image "${WEATHER_AGENT_IMAGE:-ghcr.io/kagenti/agent-examples/weather_service:latest}" \
  --env PORT=8000 \
  --env HOST=0.0.0.0 \
  --env-pass LLM_API_BASE \
  --env "LLM_API_KEY=${LLM_API_KEY:-ollama}" \
  --env "LLM_MODEL=${WEATHER_LLM_MODEL:-gpt-4o-mini}" \
  --env "OPENAI_API_KEY=${LLM_API_KEY:-dummy}" \
  --env HTTP_PROXY=http://authbridge-weather:8081 \
  --env http_proxy=http://authbridge-weather:8081 \
  --env HTTPS_PROXY=http://authbridge-weather:8081 \
  --env https_proxy=http://authbridge-weather:8081 \
  --env MCP_URL=http://weather-tool-mcp:8000/mcp \
  --env OTEL_SDK_DISABLED=true

run_container --name authbridge-weather \
  --image ghcr.io/kagenti/kagenti-extensions/authbridge:latest \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_NAME=agent-weather \
  --env AGENT_PORT=8000 \
  --env "LOG_LEVEL=${LOG_LEVEL:-info}" \
  --mount "${STACK_ROOT}/authbridge-config.yaml:/etc/authbridge/config.yaml:ro" \
  --volume broker_routes:/etc/authproxy:ro \
  --port 9001:8080 --port 9095:9093 --port 9096:9094 \
  --needs-started agent-weather \
  --needs-completed broker-routes-assemble \
  --cmd -- --config /etc/authbridge/config.yaml

oneshot --name registrar-weather --image busybox \
  --volume registry:/registry \
  --env "AGENT_ID=$AGENT_ID" \
  --env "AGENT_DESCRIPTION=$AGENT_DESCRIPTION" \
  --env AGENT_ENDPOINT=http://authbridge-weather:8080 \
  --cmd -- sh -c 'printf "{\"name\":\"%s\",\"description\":\"%s\",\"url\":\"%s\"}" "$AGENT_ID" "$AGENT_DESCRIPTION" "$AGENT_ENDPOINT" > /registry/weather.json'
