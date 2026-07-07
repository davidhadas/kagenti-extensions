# weather-tool — passthrough MCP tool (open-meteo.com, no auth). Pre-built image
# from the agent-examples repo. Published on host :8083 (container :8000; 8082 is
# taken by github-mcp).
#
# Passthrough tool: no broker route (no OAuth), so NO registrar and NO
# RESOURCE_CONFIG entry — a passthrough tool is just its server.
unit_name weather-tool
phase 20

# Override WEATHER_TOOL_IMAGE to pin a tag or point at a local build.
run_container --name weather-tool-mcp \
  --image "${WEATHER_TOOL_IMAGE:-ghcr.io/kagenti/agent-examples/weather_tool:latest}" \
  --port 8083:8000 \
  --env PORT=8000 \
  --env HOST=0.0.0.0
