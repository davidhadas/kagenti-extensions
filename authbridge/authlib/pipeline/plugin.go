package pipeline

import "context"

// Plugin is the interface that all pipeline extensions implement.
type Plugin interface {
	Name() string
	Capabilities() PluginCapabilities
	OnRequest(ctx context.Context, pctx *Context) Action
	OnResponse(ctx context.Context, pctx *Context) Action
}

// PluginCapabilities declares what extension slots a plugin reads and writes.
// The pipeline validates at startup that all reads are satisfied by an earlier
// plugin's writes.
type PluginCapabilities struct {
	Reads      []string // extension slot names this plugin reads
	Writes     []string // extension slot names this plugin writes
	BodyAccess bool     // whether this plugin needs request/response body buffered
}
