# Outbound request policy — authbridge-compose starter
#
# This policy controls every outbound call the agent makes (MCP tool calls,
# API requests, etc.) after mcp-parser and a2a-parser have classified them.
#
# Default: allow everything. Replace with real rules to enforce guardrails.
#
# To deny a specific MCP tool:
#
#   default allow := false
#   allow if { input.mcp.method != "tools/call" }
#   allow if {
#     input.mcp.method == "tools/call"
#     input.mcp.params.name != "delete_issue"
#   }
#
# See authbridge/authlib/plugins/opa/README.md for the full input schema.
package authbridge.outbound.request

default allow := true
