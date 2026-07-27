// Package ctxlogger provides a read-only diagnostic plugin that logs the
// pipeline Context — with emphasis on pctx.Session — on both the request and
// response phases, for both inbound and outbound legs. It never blocks or
// mutates anything; it always returns Continue.
//
// Purpose: answer "what does ctx.Session (and the rest of the Context) contain
// on the inbound vs. outbound OPA leg?" without modifying the OPA plugin. Place
// it in the pipeline next to `opa` so it observes the same Context OPA sees.
//
// It is intentionally verbose at INFO level so the output shows up in
// `kubectl logs ... -c authbridge-proxy` without enabling debug logging.
package ctxlogger

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/rossoctl/cortex/authbridge/authlib/pipeline"
	"github.com/rossoctl/cortex/authbridge/authlib/plugins"
)

// CtxLogger logs the pipeline Context on each phase.
type CtxLogger struct{}

// NewCtxLogger constructs the plugin.
func NewCtxLogger() *CtxLogger { return &CtxLogger{} }

func init() {
	plugins.RegisterPlugin("ctx-logger", func() pipeline.Plugin { return NewCtxLogger() })
}

// Name is the plugin's pipeline name (used in the runtime YAML).
func (p *CtxLogger) Name() string { return "ctx-logger" }

// Capabilities: read-only observer. It does not read or write the body.
func (p *CtxLogger) Capabilities() pipeline.PluginCapabilities {
	return pipeline.PluginCapabilities{
		Description: "Diagnostic: logs the pipeline Context (esp. Session) per leg/phase. Read-only.",
	}
}

// OnRequest logs the Context during the request phase, then continues.
func (p *CtxLogger) OnRequest(_ context.Context, pctx *pipeline.Context) pipeline.Action {
	p.dump("request", pctx)
	return pipeline.Action{Type: pipeline.Continue}
}

// OnResponse logs the Context during the response phase, then continues.
func (p *CtxLogger) OnResponse(_ context.Context, pctx *pipeline.Context) pipeline.Action {
	p.dump("response", pctx)
	return pipeline.Action{Type: pipeline.Continue}
}

// dump emits a single structured log line describing the Context, plus a
// dedicated line for the Session (serialized as JSON so its full shape —
// ID and Events — is visible).
func (p *CtxLogger) dump(phase string, pctx *pipeline.Context) {
	if pctx == nil {
		slog.Info("ctx-logger: nil context", "phase", phase)
		return
	}

	// Identity (nil before an auth plugin runs; nil on outbound).
	subject, clientID := "", ""
	var scopes []string
	if pctx.Identity != nil {
		subject = pctx.Identity.Subject()
		clientID = pctx.Identity.ClientID()
		scopes = pctx.Identity.Scopes()
	}

	// Agent identity (SPIFFE-derived), if present.
	agentClientID := ""
	if pctx.Agent != nil {
		agentClientID = pctx.Agent.ClientID
	}

	slog.Info("ctx-logger: context",
		"phase", phase,
		"direction", pctx.Direction.String(),
		"method", pctx.Method,
		"host", pctx.Host,
		"path", pctx.Path,
		"status_code", pctx.StatusCode, // 0 on request phase
		"identity_present", pctx.Identity != nil,
		"identity_subject", subject,
		"identity_client_id", clientID,
		"identity_scopes", scopes,
		"agent_client_id", agentClientID,
		"outbound_session_id", pctx.OutboundSessionID,
		"session_present", pctx.Session != nil,
		"ext_a2a", pctx.Extensions.A2A != nil,
		"ext_mcp", pctx.Extensions.MCP != nil,
		"ext_inference", pctx.Extensions.Inference != nil,
	)

	// The star of the show: pctx.Session. Serialize the whole SessionView
	// (ID + Events) as JSON so the exact field contents are visible per leg.
	if pctx.Session == nil {
		slog.Info("ctx-logger: session is nil",
			"phase", phase, "direction", pctx.Direction.String())
		return
	}
	blob, err := json.Marshal(pctx.Session)
	if err != nil {
		slog.Info("ctx-logger: session present but not serializable",
			"phase", phase, "direction", pctx.Direction.String(),
			"session_id", pctx.Session.ID, "events", len(pctx.Session.Events),
			"marshal_error", err.Error())
		return
	}
	slog.Info("ctx-logger: session",
		"phase", phase,
		"direction", pctx.Direction.String(),
		"session_id", pctx.Session.ID,
		"event_count", len(pctx.Session.Events),
		"session_json", string(blob),
	)
}
