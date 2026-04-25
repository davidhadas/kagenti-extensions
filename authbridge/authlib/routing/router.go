// Package routing provides host-to-audience routing for token exchange.
// Routes map destination hosts (with glob patterns) to token exchange parameters.
package routing

import (
	"fmt"
	"net"

	"github.com/gobwas/glob"
)

// Route action types.
const (
	ActionExchange    = "exchange"
	ActionPassthrough = "passthrough"
	ActionBroker      = "broker"
)

// Route defines token exchange parameters for requests to a matching host.
type Route struct {
	Host          string `yaml:"host"`
	Audience      string `yaml:"target_audience,omitempty"`
	Scopes        string `yaml:"token_scopes,omitempty"`
	TokenEndpoint string `yaml:"token_url,omitempty"`
	Action        string `yaml:"action,omitempty"` // ActionExchange, ActionPassthrough, or ActionBroker
}

// ResolvedRoute is the result of resolving a host against the router.
type ResolvedRoute struct {
	Matched        bool   // true if a configured route matched; false for default action fallback
	Action         string // ActionExchange, ActionPassthrough, or ActionBroker
	Audience       string
	Scopes         string
	TokenEndpoint  string
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
	brokerURL     string // system-wide token broker URL for broker routes
}

// NewRouter creates a router from the given routes.
// defaultAction is "exchange", "passthrough", or "broker" (applied when no route matches).
// brokerURL is the system-wide token broker service URL for broker routes.
// Returns an error if any host pattern is invalid.
func NewRouter(defaultAction string, brokerURL string, rules []Route) (*Router, error) {
	if defaultAction == "" {
		defaultAction = ActionPassthrough
	}
	// Validate defaultAction
	switch defaultAction {
	case ActionExchange, ActionPassthrough, ActionBroker:
		// valid
	default:
		return nil, fmt.Errorf("invalid defaultAction %q (valid: exchange, passthrough, broker)", defaultAction)
	}
	compiled := make([]compiledRoute, 0, len(rules))
	for i, r := range rules {
		// Validate action is a known value
		switch r.Action {
		case "", ActionExchange, ActionPassthrough, ActionBroker:
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
	return &Router{routes: compiled, defaultAction: defaultAction, brokerURL: brokerURL}, nil
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
				action = ActionExchange
			}
			switch action {
			case ActionExchange:
				return &ResolvedRoute{
					Matched:       true,
					Action:        ActionExchange,
					Audience:      entry.route.Audience,
					Scopes:        entry.route.Scopes,
					TokenEndpoint: entry.route.TokenEndpoint,
				}
			case ActionBroker:
				return &ResolvedRoute{
					Matched:        true,
					Action:         ActionBroker,
					TokenBrokerURL: r.brokerURL,
				}
			default: // ActionPassthrough
				return &ResolvedRoute{
					Matched: true,
					Action:  ActionPassthrough,
				}
			}
		}
	}
	// Handle default action when no route matches
	switch r.defaultAction {
	case ActionExchange:
		return &ResolvedRoute{Matched: false, Action: ActionExchange}
	case ActionBroker:
		return &ResolvedRoute{
			Matched:        false,
			Action:         ActionBroker,
			TokenBrokerURL: r.brokerURL,
		}
	default: // ActionPassthrough
		return nil
	}
}
