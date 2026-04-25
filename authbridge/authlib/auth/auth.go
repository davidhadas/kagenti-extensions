package auth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/bypass"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/cache"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/exchange"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/routing"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/tokenbroker"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/validation"
)

// IdentityConfig holds the agent's identity for audience validation and token exchange.
type IdentityConfig struct {
	ClientID string // agent's OAuth client ID
	Audience string // expected inbound JWT audience (usually same as ClientID)
}

// ActorTokenSource provides actor tokens for RFC 8693 Section 4.1 act claim chaining.
// Returns ("", nil) when no actor token is available.
type ActorTokenSource func(ctx context.Context) (string, error)

// AudienceDeriver derives a target audience from a request host.
// Used by waypoint mode to auto-derive audience from the destination service name.
// Returns "" if no derivation is possible (falls back to route config).
type AudienceDeriver func(host string) string

// Config holds the resolved dependencies for the auth layer.
type Config struct {
	Verifier          validation.Verifier
	Exchanger         *exchange.Client
	Cache             *cache.Cache
	Bypass            *bypass.Matcher
	Router            *routing.Router
	Identity          IdentityConfig
	NoTokenPolicy     string              // NoTokenClientCredentials, NoTokenAllow, or NoTokenDeny
	ActorTokenSource  ActorTokenSource    // optional, for act claim chaining
	AudienceDeriver   AudienceDeriver     // optional, derives audience from host (waypoint mode)
	TokenBrokerClient *tokenbroker.Client // optional, for broker routes
	Logger            *slog.Logger
}

// Auth composes authlib building blocks into inbound validation and outbound exchange.
type Auth struct {
	verifier          validation.Verifier
	exchanger         *exchange.Client
	cache             *cache.Cache
	bypass            *bypass.Matcher
	router            *routing.Router
	identity          atomic.Pointer[IdentityConfig]
	noTokenPolicy     string
	actorTokenSource  ActorTokenSource
	audienceDeriver   AudienceDeriver
	tokenBrokerClient *tokenbroker.Client
	log               *slog.Logger
}

// New creates an Auth instance from resolved configuration.
func New(cfg Config) *Auth {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	a := &Auth{
		verifier:          cfg.Verifier,
		exchanger:         cfg.Exchanger,
		cache:             cfg.Cache,
		bypass:            cfg.Bypass,
		router:            cfg.Router,
		noTokenPolicy:     cfg.NoTokenPolicy,
		actorTokenSource:  cfg.ActorTokenSource,
		audienceDeriver:   cfg.AudienceDeriver,
		tokenBrokerClient: cfg.TokenBrokerClient,
		log:               logger,
	}
	id := cfg.Identity
	a.identity.Store(&id)
	return a
}

// UpdateIdentity updates the agent's identity and exchanger credentials
// after credential files have been resolved. This is called from a background
// goroutine after the gRPC listener has started.
func (a *Auth) UpdateIdentity(id IdentityConfig, clientAuth exchange.ClientAuth) {
	a.identity.Store(&id)
	if clientAuth != nil {
		a.exchanger.UpdateAuth(clientAuth)
	}
	a.log.Info("identity updated", "client_id", id.ClientID)
}

// HandleInbound validates an inbound request's JWT token.
// audience overrides the default expected audience when non-empty. This supports
// waypoint mode where audience is derived per-request from the destination host.
// For envoy-sidecar and proxy-sidecar modes, pass "" to use the configured default.
func (a *Auth) HandleInbound(ctx context.Context, authHeader, path, audience string) *InboundResult {
	// 1. Bypass check
	if a.bypass != nil && a.bypass.Match(path) {
		a.log.Debug("bypass path matched", "path", path)
		return &InboundResult{Action: ActionAllow}
	}

	// 2. Extract bearer token
	if authHeader == "" {
		a.log.Debug("inbound denied: no Authorization header", "path", path)
		return &InboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "missing Authorization header",
		}
	}
	token := extractBearer(authHeader)
	if token == "" {
		a.log.Debug("inbound denied: malformed Authorization header", "path", path)
		return &InboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "invalid Authorization header format",
		}
	}

	// 3. Validate JWT
	if a.verifier == nil {
		return &InboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "inbound validation not configured",
		}
	}
	if audience == "" {
		audience = a.identity.Load().Audience
	}
	a.log.Debug("validating inbound JWT", "path", path, "expectedAudience", audience)
	claims, err := a.verifier.Verify(ctx, token, audience)
	if err != nil {
		// Log full error at Info; log detailed context at Debug.
		// Generic message returned to client to avoid leaking details.
		a.log.Info("JWT validation failed", "error", err)
		a.log.Debug("JWT validation details",
			"path", path,
			"expectedAudience", audience,
			"expectedIssuer", a.identity.Load().Audience,
			"error", err)
		return &InboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "token validation failed",
		}
	}

	// 4. Allow with claims
	a.log.Info("inbound authorized",
		"subject", claims.Subject, "clientID", claims.ClientID)
	a.log.Debug("inbound authorized details",
		"path", path,
		"audience", claims.Audience,
		"scopes", claims.Scopes)
	return &InboundResult{Action: ActionAllow, Claims: claims}
}

// HandleOutbound processes an outbound request, performing token exchange if needed.
func (a *Auth) HandleOutbound(ctx context.Context, authHeader, host string) *OutboundResult {
	// 1. Resolve route
	var resolved *routing.ResolvedRoute
	if a.router != nil {
		resolved = a.router.Resolve(host)
	}

	// 2. Explicit action handling
	if resolved == nil {
		a.log.Info("outbound passthrough", "host", host, "reason", "no matching route")
		return &OutboundResult{Action: ActionAllow}
	}
	if resolved.Action == routing.ActionPassthrough {
		a.log.Info("outbound passthrough", "host", host, "reason", "route action")
		return &OutboundResult{Action: ActionAllow}
	}
	if resolved.Action == routing.ActionBroker {
		return a.handleBrokerRoute(ctx, resolved, host)
	}
	if resolved.Action == routing.ActionExchange {
		return a.handleExchangeRoute(ctx, resolved, authHeader, host)
	}

	a.log.Error("unknown route action", "host", host, "action", resolved.Action)
	return &OutboundResult{
		Action:     ActionDeny,
		DenyStatus: http.StatusInternalServerError,
		DenyReason: "invalid route action",
	}
}

func (a *Auth) handleExchangeRoute(ctx context.Context, resolved *routing.ResolvedRoute, authHeader, host string) *OutboundResult {
	// Determine audience/scopes
	audience := resolved.Audience
	scopes := resolved.Scopes

	// If no audience from route and deriver is set, derive from host (waypoint pattern)
	if audience == "" && a.audienceDeriver != nil {
		audience = a.audienceDeriver(host)
		a.log.Debug("audience derived from host", "host", host, "audience", audience)
	}

	a.log.Debug("outbound exchange requested",
		"host", host, "audience", audience, "scopes", scopes,
		"hasSubjectToken", authHeader != "")

	// Extract bearer token
	subjectToken := extractBearer(authHeader)

	if subjectToken == "" {
		// No token — apply no-token policy
		a.log.Debug("no subject token, applying no-token policy",
			"policy", a.noTokenPolicy, "host", host, "audience", audience)
		return a.handleNoToken(ctx, audience, scopes)
	}

	// Cache check
	if a.cache != nil {
		if cached, ok := a.cache.Get(subjectToken, audience); ok {
			a.log.Debug("outbound cache hit", "host", host, "audience", audience)
			return &OutboundResult{Action: ActionReplaceToken, Token: cached}
		}
	}

	// Token exchange
	if a.exchanger == nil {
		a.log.Warn("exchanger not configured, passing through",
			"host", host, "audience", audience)
		return &OutboundResult{Action: ActionAllow}
	}

	// Obtain actor token for act claim chaining (RFC 8693 Section 4.1)
	var actorToken string
	if a.actorTokenSource != nil {
		var err error
		actorToken, err = a.actorTokenSource(ctx)
		if err != nil {
			a.log.Warn("failed to obtain actor token, proceeding without",
				"error", err, "host", host)
		}
	}

	resp, err := a.exchanger.Exchange(ctx, &exchange.ExchangeRequest{
		SubjectToken:  subjectToken,
		Audience:      audience,
		Scopes:        scopes,
		ActorToken:    actorToken,
		TokenEndpoint: resolved.TokenEndpoint, // per-route override
	})
	if err != nil {
		a.log.Info("token exchange failed", "host", host, "error", err)
		a.log.Debug("token exchange failure details",
			"host", host,
			"audience", audience,
			"scopes", scopes,
			"hasActorToken", actorToken != "",
			"tokenEndpoint", resolved.TokenEndpoint,
			"error", err)
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusServiceUnavailable,
			DenyReason: "token exchange failed",
		}
	}

	// Cache result
	if a.cache != nil && resp.ExpiresIn > 0 {
		a.cache.Set(subjectToken, audience, resp.AccessToken,
			time.Duration(resp.ExpiresIn)*time.Second)
	}

	a.log.Info("outbound token exchanged", "host", host, "audience", audience)
	a.log.Debug("outbound exchange details",
		"host", host, "audience", audience, "expiresIn", resp.ExpiresIn)
	return &OutboundResult{Action: ActionReplaceToken, Token: resp.AccessToken}
}

func (a *Auth) handleBrokerRoute(ctx context.Context, resolved *routing.ResolvedRoute, host string) *OutboundResult {
	if a.tokenBrokerClient == nil {
		a.log.Error("broker route but no Token Broker client configured", "host", host)
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusServiceUnavailable,
			DenyReason: "Token Broker not configured",
		}
	}
	return a.handleBroker(ctx, resolved, host)
}

func (a *Auth) handleBroker(ctx context.Context, resolved *routing.ResolvedRoute, host string) *OutboundResult {
	// Extract JWT token from Authorization header
	headers := HeadersFromContext(ctx)
	authHeader := headers["authorization"]
	if authHeader == "" {
		a.log.Warn("missing Authorization header for broker route")
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "Failed to obtain user authorization for this MCP server.",
			Broker:     true,
		}
	}

	token := extractBearer(authHeader)
	if token == "" {
		a.log.Warn("malformed Authorization header for broker route")
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "Failed to obtain user authorization for this MCP server.",
			Broker:     true,
		}
	}

	// Derive target server URL from destination host
	serverURL := "http://" + host

	a.log.Info("acquiring token from Token Broker",
		"server_url", serverURL)

	// Call Token Broker (blocks until token available)
	// The broker will extract user_id and session_key from the token
	brokerToken, err := a.tokenBrokerClient.AcquireToken(ctx, resolved.TokenBrokerURL, token, serverURL)
	if err != nil {
		a.log.Error("token broker acquisition failed",
			"server_url", serverURL,
			"error", err)
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusForbidden,
			DenyReason: "Failed to obtain user authorization for this MCP server.",
			Broker:     true,
		}
	}

	a.log.Info("token acquired from Token Broker",
		"server_url", serverURL)

	return &OutboundResult{Action: ActionReplaceToken, Token: brokerToken}
}

func (a *Auth) handleNoToken(ctx context.Context, audience, scopes string) *OutboundResult {
	switch a.noTokenPolicy {
	case NoTokenPolicyAllow:
		a.log.Debug("no token, policy=allow")
		return &OutboundResult{Action: ActionAllow}

	case NoTokenPolicyClientCredentials:
		if a.exchanger == nil {
			a.log.Debug("no token, client_credentials requested but exchanger not configured",
				"audience", audience)
			return &OutboundResult{
				Action:     ActionDeny,
				DenyStatus: http.StatusServiceUnavailable,
				DenyReason: "exchanger not configured for client credentials",
			}
		}
		a.log.Debug("no token, falling back to client_credentials",
			"audience", audience, "scopes", scopes)
		resp, err := a.exchanger.ClientCredentials(ctx, audience, scopes)
		if err != nil {
			a.log.Info("client credentials grant failed", "error", err)
			a.log.Debug("client credentials failure details",
				"audience", audience, "scopes", scopes, "error", err)
			return &OutboundResult{
				Action:     ActionDeny,
				DenyStatus: http.StatusServiceUnavailable,
				DenyReason: "client credentials token acquisition failed",
			}
		}
		return &OutboundResult{Action: ActionReplaceToken, Token: resp.AccessToken}

	default: // NoTokenDeny or unknown
		a.log.Debug("no token, policy denies request",
			"policy", a.noTokenPolicy, "audience", audience)
		return &OutboundResult{
			Action:     ActionDeny,
			DenyStatus: http.StatusUnauthorized,
			DenyReason: "missing Authorization header",
		}
	}
}

func extractBearer(authHeader string) string {
	// RFC 7235: auth scheme is case-insensitive
	if len(authHeader) > 7 && strings.EqualFold(authHeader[:7], "bearer ") {
		return authHeader[7:]
	}
	return ""
}

// jwtClaims represents the JWT claims we need to extract
type jwtClaims struct {
	JTI               string `json:"jti"`                // JWT ID - used as session_key
	Sub               string `json:"sub"`                // Subject (user ID)
	PreferredUsername string `json:"preferred_username"` // Username - preferred for user_id
}

// extractJWTClaims extracts claims from a JWT token without verifying the signature.
// This is acceptable for internal communication where the token has already been validated by the backend.
func extractJWTClaims(token string) (*jwtClaims, error) {
	// Step 1: Split token into parts
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("invalid JWT format: expected 3 parts, got %d", len(parts))
	}

	// Step 2: Decode payload (second part)
	payload := parts[1]
	// Add padding if needed for base64 decoding
	if l := len(payload) % 4; l > 0 {
		payload += strings.Repeat("=", 4-l)
	}

	payloadBytes, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to decode JWT payload: %w", err)
	}

	// Step 3: Parse JSON claims
	var claims jwtClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, fmt.Errorf("failed to parse JWT claims: %w", err)
	}

	return &claims, nil
}

// getUserID extracts the user ID from JWT claims.
// Prefers preferred_username, falls back to sub.
func getUserID(claims *jwtClaims) string {
	if claims.PreferredUsername != "" {
		return claims.PreferredUsername
	}
	return claims.Sub
}

// extractUUIDFromJTI extracts the UUID from Keycloak's jti claim.
// Keycloak's jti format is "<prefix>:<uuid>", we need just the UUID part.
func extractUUIDFromJTI(jti string) string {
	// Find the last colon and return everything after it
	if idx := strings.LastIndex(jti, ":"); idx != -1 {
		return jti[idx+1:]
	}
	// If no colon found, return the whole jti (already a UUID)
	return jti
}
