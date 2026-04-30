package pipeline

import "time"

// Extensions holds typed extension slots for plugin-to-plugin communication.
// Each slot is populated by a specific plugin and consumed by downstream plugins.
type Extensions struct {
	MCP        *MCPExtension
	A2A        *A2AExtension
	Security   *SecurityExtension
	Delegation *DelegationExtension
	Custom     map[string]any
}

// MCPExtension carries parsed MCP JSON-RPC metadata.
// Exactly one of Tool, Resource, or Prompt is populated per request.
type MCPExtension struct {
	Method string // JSON-RPC method: "tools/call", "resources/read", "prompts/get"
	RPCID  any    // JSON-RPC id for request-response correlation

	Tool     *MCPToolMetadata
	Resource *MCPResourceMetadata
	Prompt   *MCPPromptMetadata
}

// MCPToolMetadata is populated for tools/call requests.
type MCPToolMetadata struct {
	Name string
	Args map[string]any
}

// MCPResourceMetadata is populated for resources/read requests.
type MCPResourceMetadata struct {
	URI string
}

// MCPPromptMetadata is populated for prompts/get requests.
type MCPPromptMetadata struct {
	Name string
	Args map[string]string
}

// A2AExtension carries parsed A2A protocol metadata.
type A2AExtension struct {
	TaskID string
	Method string // "tasks/send", "tasks/get", etc.
	Parts  []A2APart
}

// A2APart represents a message part in an A2A request.
type A2APart struct {
	Type    string // "text", "file", "data"
	Content string
}

// SecurityExtension carries guardrail output.
// Caller identity is already in ctx.Agent and ctx.Claims — this slot is only
// for downstream signals from content-inspection plugins.
type SecurityExtension struct {
	Labels      []string
	Blocked     bool
	BlockReason string
}

// DelegationExtension tracks the token delegation chain across hops.
type DelegationExtension struct {
	Chain  []DelegationHop
	Depth  int
	Origin string // original caller's subject ID
	Actor  string // current actor's subject ID
}

// DelegationHop represents one hop in the delegation chain.
type DelegationHop struct {
	SubjectID string
	Scopes    []string
	Timestamp time.Time
}

// AppendHop adds a hop to the delegation chain. Plugins should use this method
// rather than mutating Chain directly — the chain is intended to be append-only.
func (d *DelegationExtension) AppendHop(hop DelegationHop) {
	d.Chain = append(d.Chain, hop)
	d.Depth = len(d.Chain)
	if d.Origin == "" {
		d.Origin = hop.SubjectID
	}
	d.Actor = hop.SubjectID
}
