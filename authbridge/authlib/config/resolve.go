package config

import (
	"context"
	"fmt"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/auth"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/bypass"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/cache"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/exchange"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/routing"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/spiffe"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/validation"
)

// Resolve applies presets, validates, and instantiates all authlib components
// from the configuration. Returns a fully wired auth.Config ready for auth.New().
func Resolve(ctx context.Context, cfg *Config) (*auth.Config, error) {
	ApplyPreset(cfg)

	if err := Validate(cfg); err != nil {
		return nil, fmt.Errorf("config validation: %w", err)
	}
	if err := ValidateOutboundPolicy(cfg.Outbound.DefaultPolicy); err != nil {
		return nil, err
	}

	// Bypass matcher
	matcher, err := bypass.NewMatcher(cfg.Bypass.InboundPaths)
	if err != nil {
		return nil, fmt.Errorf("bypass patterns: %w", err)
	}

	// JWT verifier
	verifier, err := validation.NewJWKSVerifier(ctx, cfg.Inbound.JWKSURL, cfg.Inbound.Issuer)
	if err != nil {
		return nil, fmt.Errorf("JWKS verifier: %w", err)
	}

	// Client auth for token exchange
	clientAuth, err := resolveClientAuth(cfg)
	if err != nil {
		return nil, fmt.Errorf("client auth: %w", err)
	}

	exchanger := exchange.NewClient(cfg.Outbound.TokenURL, clientAuth)

	// Router
	router, err := resolveRouter(cfg)
	if err != nil {
		return nil, fmt.Errorf("router: %w", err)
	}

	return &auth.Config{
		Verifier:  verifier,
		Exchanger: exchanger,
		Cache:     cache.New(),
		Bypass:    matcher,
		Router:    router,
		Identity: auth.IdentityConfig{
			ClientID: cfg.Identity.ClientID,
			Audience: cfg.Identity.ClientID, // inbound audience defaults to client ID
		},
		NoTokenPolicy: NoTokenPolicyForMode(cfg.Mode),
	}, nil
}

func resolveClientAuth(cfg *Config) (exchange.ClientAuth, error) {
	switch cfg.Identity.Type {
	case "spiffe":
		if cfg.Identity.JWTSVIDPath != "" {
			source := spiffe.NewFileJWTSource(cfg.Identity.JWTSVIDPath)
			return &exchange.JWTAssertionAuth{
				ClientID:      cfg.Identity.ClientID,
				AssertionType: "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe",
				TokenSource:   source.FetchToken,
			}, nil
		}
		return nil, fmt.Errorf("spiffe identity requires jwt_svid_path (Workload API not yet supported)")

	case "client-secret":
		return &exchange.ClientSecretAuth{
			ClientID:     cfg.Identity.ClientID,
			ClientSecret: cfg.Identity.ClientSecret,
		}, nil

	default:
		return nil, fmt.Errorf("unsupported identity type %q for client auth", cfg.Identity.Type)
	}
}

func resolveRouter(cfg *Config) (*routing.Router, error) {
	var rules []routing.Route

	// Load from file if specified
	if cfg.Routes.File != "" {
		fileRoutes, err := routing.LoadRoutes(cfg.Routes.File)
		if err != nil {
			return nil, err
		}
		rules = append(rules, fileRoutes...)
	}

	// Add inline rules, converting from RouteConfig to routing.Route
	for _, rc := range cfg.Routes.Rules {
		action := rc.Action
		if action == "" && rc.Passthrough {
			action = "passthrough" // backwards compatibility
		}
		rules = append(rules, routing.Route{
			Host:          rc.Host,
			Audience:      rc.TargetAudience,
			Scopes:        rc.TokenScopes,
			TokenEndpoint: rc.TokenURL,
			Action:        action,
		})
	}

	return routing.NewRouter(cfg.Outbound.DefaultPolicy, rules)
}
