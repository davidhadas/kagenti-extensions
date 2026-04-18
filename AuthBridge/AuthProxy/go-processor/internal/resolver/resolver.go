// Package resolver provides abstractions for mapping destination hosts
// to token exchange configuration.
package resolver

import "context"

// AuthMode defines how AuthBridge should handle outbound authentication
// for a matched target route.
type AuthMode string

const (
	// AuthModeService uses the existing service-oriented token acquisition flow.
	AuthModeService AuthMode = "service"

	// AuthModePassthrough forwards traffic without token acquisition or exchange.
	AuthModePassthrough AuthMode = "passthrough"

	// AuthModeUserOAuth enables user-driven OAuth elicitation for MCP targets.
	AuthModeUserOAuth AuthMode = "user_oauth"
)

// TargetConfig describes the authentication parameters for a target service.
// We use "target" terminology deliberately - these are resource servers that
// receive tokens, not OAuth clients that request them.
type TargetConfig struct {
	// AuthMode selects the outbound authentication strategy for this target.
	// Empty values should be treated by callers as AuthModeService for backward compatibility.
	AuthMode AuthMode

	// Audience identifies the target resource server.
	// This becomes the "aud" claim in the exchanged token.
	Audience string

	// Scopes are the permissions to request in the exchanged token.
	Scopes string

	// TokenEndpoint overrides the default token endpoint for this target.
	// If empty, the global token endpoint is used.
	TokenEndpoint string
}

// TargetResolver maps a destination host to its token exchange configuration.
// Implementations may use static configuration, IDP lookups, or other strategies.
type TargetResolver interface {
	// Resolve returns the exchange configuration for the given host.
	// Returns nil (not error) if no specific configuration exists,
	// in which case the caller should use default/global configuration.
	Resolve(ctx context.Context, host string) (*TargetConfig, error)
}
