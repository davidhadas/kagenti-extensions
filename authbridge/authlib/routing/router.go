// Package routing provides host-to-audience routing for token exchange.
// Routes map destination hosts (with glob patterns) to token exchange parameters.
package routing

import (
	"fmt"
	"net"

	"github.com/gobwas/glob"
)

// Route defines token exchange parameters for requests to a matching host.
type Route struct {
	Host           string `yaml:"host"`
	Audience       string `yaml:"target_audience,omitempty"`
	Scopes         string `yaml:"token_scopes,omitempty"`
	TokenEndpoint  string `yaml:"token_url,omitempty"`
	Action         string `yaml:"action,omitempty"`           // "exchange", "passthrough", or "broker"
	TokenBrokerURL string `yaml:"token_broker_url,omitempty"` // required when action == "broker"
}

// ResolvedRoute is the result of resolving a host against the router.
type ResolvedRoute struct {
	Matched        bool // true if a configured route matched; false for default action fallback
	Audience       string
	Scopes         string
	TokenEndpoint  string
	Passthrough    bool
	Broker         bool   // true when action == "broker"
	TokenBrokerURL string // Token Broker base URL for broker routes
}

type compiledRoute struct {
	pattern string
	glob    glob.Glob
	route   Route
}

// Router resolves destination hosts to token exchange configuration.
// Uses first-match-wins semantics with gobwas/glob patterns.
type Router struct {
	routes        []compiledRoute
	defaultAction string // "exchange" or "passthrough"
}

// NewRouter creates a router from the given routes.
// defaultAction is "exchange" or "passthrough" (applied when no route matches).
// Returns an error if any host pattern is invalid.
func NewRouter(defaultAction string, rules []Route) (*Router, error) {
	if defaultAction == "" {
		defaultAction = "passthrough"
	}
	compiled := make([]compiledRoute, 0, len(rules))
	for i, r := range rules {
		// Validate broker routes have token_broker_url
		if r.Action == "broker" && r.TokenBrokerURL == "" {
			return nil, fmt.Errorf("route %d (host %q): action \"broker\" requires token_broker_url", i, r.Host)
		}
		// Validate action is a known value
		switch r.Action {
		case "", "exchange", "passthrough", "broker":
			// valid
		default:
			return nil, fmt.Errorf("route %d (host %q): unknown action %q", i, r.Host, r.Action)
		}
		// Use '.' as separator so *.example.com doesn't match foo.bar.example.com
		g, err := glob.Compile(r.Host, '.')
		if err != nil {
			return nil, fmt.Errorf("invalid route pattern %q: %w", r.Host, err)
		}
		compiled = append(compiled, compiledRoute{
			pattern: r.Host,
			glob:    g,
			route:   r,
		})
	}
	return &Router{routes: compiled, defaultAction: defaultAction}, nil
}

// Resolve returns the exchange configuration for the given host.
// Returns nil if no route matches and the default action is "passthrough".
// Port is stripped from the host before matching.
func (r *Router) Resolve(host string) *ResolvedRoute {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	for _, entry := range r.routes {
		if entry.glob.Match(host) {
			action := entry.route.Action
			if action == "" {
				action = "exchange"
			}
			switch action {
			case "passthrough":
				return &ResolvedRoute{
					Matched:     true,
					Passthrough: true,
				}
			case "broker":
				return &ResolvedRoute{
					Matched:        true,
					Broker:         true,
					TokenBrokerURL: entry.route.TokenBrokerURL,
				}
			default: // "exchange"
				return &ResolvedRoute{
					Matched:       true,
					Audience:      entry.route.Audience,
					Scopes:        entry.route.Scopes,
					TokenEndpoint: entry.route.TokenEndpoint,
				}
			}
		}
	}
	if r.defaultAction == "exchange" {
		return &ResolvedRoute{Matched: false}
	}
	return nil
}
