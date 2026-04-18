package resolver

import (
	"context"
	"log"
	"net"
	"os"
	"sync"

	"github.com/gobwas/glob"
	"gopkg.in/yaml.v3"
)

// yamlRoute is the configuration file format for route entries.
type yamlRoute struct {
	Host           string   `yaml:"host"`
	AuthMode       AuthMode `yaml:"auth_mode,omitempty"`
	TargetAudience string   `yaml:"target_audience,omitempty"`
	TokenScopes    string   `yaml:"token_scopes,omitempty"`
	TokenURL       string   `yaml:"token_url,omitempty"`
	Passthrough    bool     `yaml:"passthrough,omitempty"`
}

type routeEntry struct {
	pattern string
	glob    glob.Glob
	config  TargetConfig
}

// StaticResolver resolves targets from a YAML configuration file.
type StaticResolver struct {
	routes []routeEntry
	mu     sync.RWMutex
}

// NewStaticResolver loads routes from a YAML file.
// Returns a resolver with no routes if the file doesn't exist.
func NewStaticResolver(configPath string) (*StaticResolver, error) {
	r := &StaticResolver{}

	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		log.Printf("[Resolver] No routes config at %s, using defaults", configPath)
		return r, nil
	}

	content, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	var routes []yamlRoute
	if err := yaml.Unmarshal(content, &routes); err != nil {
		return nil, err
	}

	r.routes = make([]routeEntry, 0, len(routes))
	for _, yr := range routes {
		// Use '.' as separator so *.example.com doesn't match foo.bar.example.com
		g, err := glob.Compile(yr.Host, '.')
		if err != nil {
			log.Printf("[Resolver] Invalid pattern %q: %v, skipping", yr.Host, err)
			continue
		}

		authMode := yr.AuthMode
		if authMode == "" {
			if yr.Passthrough {
				authMode = AuthModePassthrough
			} else {
				authMode = AuthModeService
			}
		}

		r.routes = append(r.routes, routeEntry{
			pattern: yr.Host,
			glob:    g,
			config: TargetConfig{
				AuthMode:      authMode,
				Audience:      yr.TargetAudience,
				Scopes:        yr.TokenScopes,
				TokenEndpoint: yr.TokenURL,
			},
		})
	}

	log.Printf("[Resolver] Loaded %d routes", len(r.routes))
	return r, nil
}

// Resolve returns the configuration for the given host.
// Returns nil if no route matches.
func (r *StaticResolver) Resolve(ctx context.Context, host string) (*TargetConfig, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}

	for _, entry := range r.routes {
		if entry.glob.Match(host) {
			log.Printf("[Resolver] Host %q matched %q", host, entry.pattern)
			config := entry.config
			return &config, nil
		}
	}

	return nil, nil
}
