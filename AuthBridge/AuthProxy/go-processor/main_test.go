package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	v3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"github.com/kagenti/kagenti-extensions/AuthBridge/AuthProxy/go-processor/internal/resolver"
)

func TestMatchBypassPath(t *testing.T) {
	tests := []struct {
		name         string
		patterns     []string
		requestPath  string
		expectBypass bool
	}{
		{
			name:         "exact match /healthz",
			patterns:     []string{"/healthz", "/readyz"},
			requestPath:  "/healthz",
			expectBypass: true,
		},
		{
			name:         "exact match /readyz",
			patterns:     []string{"/healthz", "/readyz"},
			requestPath:  "/readyz",
			expectBypass: true,
		},
		{
			name:         "glob match /.well-known/*",
			patterns:     []string{"/.well-known/*"},
			requestPath:  "/.well-known/agent.json",
			expectBypass: true,
		},
		{
			name:         "glob does not match nested path",
			patterns:     []string{"/.well-known/*"},
			requestPath:  "/.well-known/a/b",
			expectBypass: false,
		},
		{
			name:         "no match for /api/data",
			patterns:     []string{"/.well-known/*", "/healthz", "/readyz", "/livez"},
			requestPath:  "/api/data",
			expectBypass: false,
		},
		{
			name:         "empty bypass list",
			patterns:     []string{},
			requestPath:  "/healthz",
			expectBypass: false,
		},
		{
			name:         "nil bypass list",
			patterns:     nil,
			requestPath:  "/healthz",
			expectBypass: false,
		},
		{
			name:         "path with query string - matches",
			patterns:     []string{"/healthz"},
			requestPath:  "/healthz?verbose=true",
			expectBypass: true,
		},
		{
			name:         "path with query string - glob matches",
			patterns:     []string{"/.well-known/*"},
			requestPath:  "/.well-known/agent.json?format=json",
			expectBypass: true,
		},
		{
			name:         "path with query string - no match",
			patterns:     []string{"/healthz"},
			requestPath:  "/api/data?healthz=true",
			expectBypass: false,
		},
		{
			name:         "empty request path",
			patterns:     []string{"/healthz"},
			requestPath:  "",
			expectBypass: false,
		},
		{
			name:         "root path exact match",
			patterns:     []string{"/"},
			requestPath:  "/",
			expectBypass: true,
		},
		// Malformed pattern: silently skipped, does not match
		{
			name:         "malformed pattern is skipped",
			patterns:     []string{"["},
			requestPath:  "/healthz",
			expectBypass: false,
		},
		{
			name:         "malformed pattern does not block valid patterns",
			patterns:     []string{"[", "/healthz"},
			requestPath:  "/healthz",
			expectBypass: true,
		},
		// Path normalization: non-canonical forms should still match
		{
			name:         "double slash normalized",
			patterns:     []string{"/healthz"},
			requestPath:  "//healthz",
			expectBypass: true,
		},
		{
			name:         "dot segment normalized",
			patterns:     []string{"/healthz"},
			requestPath:  "/./healthz",
			expectBypass: true,
		},
		{
			name:         "dot-dot segment normalized",
			patterns:     []string{"/.well-known/*"},
			requestPath:  "/foo/../.well-known/agent.json",
			expectBypass: true,
		},
		{
			name:         "trailing slash normalized",
			patterns:     []string{"/healthz"},
			requestPath:  "/healthz/",
			expectBypass: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Save and restore the global state
			orig := bypassInboundPaths
			bypassInboundPaths = tt.patterns
			defer func() { bypassInboundPaths = orig }()

			got := matchBypassPath(tt.requestPath)
			if got != tt.expectBypass {
				t.Errorf("matchBypassPath(%q) = %v, want %v (patterns: %v)",
					tt.requestPath, got, tt.expectBypass, tt.patterns)
			}
		})
	}
}

func TestDefaultBypassPaths(t *testing.T) {
	// Verify defaults are applied without any env var override
	orig := bypassInboundPaths
	bypassInboundPaths = defaultBypassInboundPaths
	defer func() { bypassInboundPaths = orig }()

	shouldBypass := []string{
		"/.well-known/agent.json",
		"/.well-known/openid-configuration",
		"/healthz",
		"/readyz",
		"/livez",
	}
	for _, p := range shouldBypass {
		if !matchBypassPath(p) {
			t.Errorf("default bypass should match %q but did not", p)
		}
	}

	shouldBlock := []string{
		"/",
		"/api/data",
		"/v1/tasks",
		"/.well-known/nested/deep",
	}
	for _, p := range shouldBlock {
		if matchBypassPath(p) {
			t.Errorf("default bypass should NOT match %q but did", p)
		}
	}
}

// --- Test helpers ---

// buildHeaders creates a core.HeaderMap with the given host and optional Authorization header.
func buildHeaders(host, authHeader string) *core.HeaderMap {
	headers := []*core.HeaderValue{
		{Key: ":authority", RawValue: []byte(host)},
		{Key: ":path", RawValue: []byte("/")},
		{Key: ":method", RawValue: []byte("GET")},
	}
	if authHeader != "" {
		headers = append(headers, &core.HeaderValue{
			Key:      "authorization",
			RawValue: []byte(authHeader),
		})
	}
	return &core.HeaderMap{Headers: headers}
}

// setupTestResolver creates a StaticResolver from inline YAML for testing.
func setupTestResolver(t *testing.T, yaml string) resolver.TargetResolver {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "routes.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatalf("failed to write test routes.yaml: %v", err)
	}
	r, err := resolver.NewStaticResolver(path)
	if err != nil {
		t.Fatalf("failed to create resolver: %v", err)
	}
	return r
}

// emptyResolver returns a resolver with no routes (simulates missing routes.yaml).
func emptyResolver(t *testing.T) resolver.TargetResolver {
	t.Helper()
	r, err := resolver.NewStaticResolver("/nonexistent/path/routes.yaml")
	if err != nil {
		t.Fatalf("unexpected error creating empty resolver: %v", err)
	}
	return r
}

// mockKeycloak starts a test HTTP server that mimics Keycloak's token endpoint.
func mockKeycloak(t *testing.T, statusCode int, responseBody interface{}) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(statusCode)
		json.NewEncoder(w).Encode(responseBody)
	}))
}

// isPassthrough returns true if the response forwards the request unchanged.
func isPassthrough(resp *v3.ProcessingResponse) bool {
	rh, ok := resp.Response.(*v3.ProcessingResponse_RequestHeaders)
	if !ok {
		return false
	}
	return rh.RequestHeaders.Response == nil || rh.RequestHeaders.Response.HeaderMutation == nil
}

// isDenied returns true if the response is an ImmediateResponse (503).
func isDenied(resp *v3.ProcessingResponse) bool {
	_, ok := resp.Response.(*v3.ProcessingResponse_ImmediateResponse)
	return ok
}

// hasReplacedAuthHeader returns true if the response mutates the Authorization header.
func hasReplacedAuthHeader(resp *v3.ProcessingResponse) (string, bool) {
	rh, ok := resp.Response.(*v3.ProcessingResponse_RequestHeaders)
	if !ok {
		return "", false
	}
	if rh.RequestHeaders.Response == nil || rh.RequestHeaders.Response.HeaderMutation == nil {
		return "", false
	}
	for _, h := range rh.RequestHeaders.Response.HeaderMutation.SetHeaders {
		if strings.EqualFold(h.Header.Key, "authorization") {
			return string(h.Header.RawValue), true
		}
	}
	return "", false
}

type savedGlobals struct {
	policy         string
	resolver       resolver.TargetResolver
	clientID       string
	clientSecret   string
	tokenURL       string
	targetAudience string
	targetScopes   string
}

func saveGlobals() savedGlobals {
	globalConfig.mu.RLock()
	defer globalConfig.mu.RUnlock()
	return savedGlobals{
		policy:         defaultOutboundPolicy,
		resolver:       globalResolver,
		clientID:       globalConfig.ClientID,
		clientSecret:   globalConfig.ClientSecret,
		tokenURL:       globalConfig.TokenURL,
		targetAudience: globalConfig.TargetAudience,
		targetScopes:   globalConfig.TargetScopes,
	}
}

func restoreGlobals(saved savedGlobals) {
	defaultOutboundPolicy = saved.policy
	globalResolver = saved.resolver
	globalConfig.mu.Lock()
	defer globalConfig.mu.Unlock()
	globalConfig.ClientID = saved.clientID
	globalConfig.ClientSecret = saved.clientSecret
	globalConfig.TokenURL = saved.tokenURL
	globalConfig.TargetAudience = saved.targetAudience
	globalConfig.TargetScopes = saved.targetScopes
}

func setGlobalConfig(clientID, clientSecret, tokenURL, audience, scopes string) {
	globalConfig.mu.Lock()
	defer globalConfig.mu.Unlock()
	globalConfig.ClientID = clientID
	globalConfig.ClientSecret = clientSecret
	globalConfig.TokenURL = tokenURL
	globalConfig.TargetAudience = audience
	globalConfig.TargetScopes = scopes
}

// --- Test: Default agents (weather-service pattern) ---

// TestDefaultOutboundPolicy verifies that agents without routes.yaml get passthrough
// behavior by default. This models the weather-service scenario: an agent calling
// Ollama (LLM), otel-collector (telemetry), or any other service that doesn't
// need Keycloak token exchange.
func TestDefaultOutboundPolicy(t *testing.T) {
	tests := []struct {
		name           string
		policy         string
		host           string
		authHeader     string
		globalConfig   bool // whether to set complete global config
		expectPassthru bool
	}{
		{
			name:           "passthrough_default_ollama",
			policy:         "passthrough",
			host:           "ollama-service.team1.svc.cluster.local",
			expectPassthru: true,
		},
		{
			name:           "passthrough_default_otel",
			policy:         "passthrough",
			host:           "otel-collector.kagenti-system.svc.cluster.local:8335",
			expectPassthru: true,
		},
		{
			name:           "passthrough_default_any_host",
			policy:         "passthrough",
			host:           "random-service.default.svc.cluster.local",
			expectPassthru: true,
		},
		{
			name:           "passthrough_with_auth_header",
			policy:         "passthrough",
			host:           "ollama-service.team1.svc.cluster.local",
			authHeader:     "Bearer sk-some-api-key",
			expectPassthru: true,
		},
		{
			name:           "passthrough_unset_env_defaults_to_passthrough",
			policy:         "", // empty = not set, should keep default "passthrough"
			host:           "any-host.example.com",
			expectPassthru: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			saved := saveGlobals()
			defer restoreGlobals(saved)

			if tt.policy != "" {
				defaultOutboundPolicy = tt.policy
			}
			globalResolver = emptyResolver(t)

			if tt.globalConfig {
				setGlobalConfig("test-client", "test-secret", "http://keycloak/token", "test-aud", "openid")
			} else {
				setGlobalConfig("", "", "", "", "")
			}

			p := &processor{}
			headers := buildHeaders(tt.host, tt.authHeader)
			resp := p.handleOutbound(context.Background(), headers)

			if tt.expectPassthru && !isPassthrough(resp) {
				t.Errorf("expected passthrough for host %q with policy %q, but got non-passthrough response", tt.host, tt.policy)
			}
			if !tt.expectPassthru && isPassthrough(resp) {
				t.Errorf("expected non-passthrough for host %q with policy %q, but got passthrough", tt.host, tt.policy)
			}
		})
	}
}

// TestDefaultOutboundPolicyLegacyExchange verifies backward compatibility:
// when DEFAULT_OUTBOUND_POLICY=exchange and global config is complete, unmatched
// hosts still get token exchange (the old behavior).
func TestDefaultOutboundPolicyLegacyExchange(t *testing.T) {
	saved := saveGlobals()
	defer restoreGlobals(saved)

	keycloak := mockKeycloak(t, http.StatusOK, tokenExchangeResponse{
		AccessToken: "legacy-exchanged-token",
		TokenType:   "Bearer",
		ExpiresIn:   300,
	})
	defer keycloak.Close()

	defaultOutboundPolicy = "exchange"
	globalResolver = emptyResolver(t)
	setGlobalConfig("test-client", "test-secret", keycloak.URL, "test-audience", "openid test-aud")

	p := &processor{}
	headers := buildHeaders("random-service.example.com", "Bearer some-jwt-token")
	resp := p.handleOutbound(context.Background(), headers)

	token, ok := hasReplacedAuthHeader(resp)
	if !ok {
		if isDenied(resp) {
			t.Fatal("legacy exchange policy: expected token exchange to succeed, but got 503 denial")
		}
		t.Fatal("legacy exchange policy: expected Authorization header to be replaced, but got passthrough")
	}
	if token != "Bearer legacy-exchanged-token" {
		t.Errorf("expected 'Bearer legacy-exchanged-token', got %q", token)
	}
}

// --- Test: Github-issue agent pattern (route-based exchange) ---

// TestOutboundPolicyWithRoutes verifies that agents with routes.yaml entries
// get token exchange only for matched hosts. This models the github-issue agent:
// calls to github-tool get exchange, calls to the LLM pass through.
func TestOutboundPolicyWithRoutes(t *testing.T) {
	saved := saveGlobals()
	defer restoreGlobals(saved)

	keycloak := mockKeycloak(t, http.StatusOK, tokenExchangeResponse{
		AccessToken: "exchanged-token-for-github-tool",
		TokenType:   "Bearer",
		ExpiresIn:   300,
	})
	defer keycloak.Close()

	routesYAML := fmt.Sprintf(`
- host: "github-issue-tool-headless.team1.svc.cluster.local"
  target_audience: "github-tool"
  token_scopes: "openid github-tool-aud github-full-access"
  token_url: %q
- host: "otel-collector.*.svc.cluster.local"
  passthrough: true
`, keycloak.URL)

	defaultOutboundPolicy = "passthrough"
	globalResolver = setupTestResolver(t, routesYAML)
	setGlobalConfig("spiffe://localtest.me/ns/team1/sa/github-issue-agent", "client-secret-123", keycloak.URL, "", "")

	t.Run("route_match_exchanges_token", func(t *testing.T) {
		p := &processor{}
		headers := buildHeaders("github-issue-tool-headless.team1.svc.cluster.local", "Bearer valid-jwt-from-keycloak")
		resp := p.handleOutbound(context.Background(), headers)

		token, ok := hasReplacedAuthHeader(resp)
		if !ok {
			if isDenied(resp) {
				t.Fatal("expected exchange to succeed, but got 503 denial")
			}
			t.Fatal("expected Authorization header to be replaced, but got passthrough")
		}
		if token != "Bearer exchanged-token-for-github-tool" {
			t.Errorf("expected 'Bearer exchanged-token-for-github-tool', got %q", token)
		}
	})

	t.Run("route_match_no_auth_header_uses_client_credentials", func(t *testing.T) {
		p := &processor{}
		headers := buildHeaders("github-issue-tool-headless.team1.svc.cluster.local", "")
		resp := p.handleOutbound(context.Background(), headers)

		token, ok := hasReplacedAuthHeader(resp)
		if !ok {
			if isDenied(resp) {
				t.Fatal("expected client_credentials to succeed, but got 503 denial")
			}
			t.Fatal("expected Authorization header to be injected via client_credentials, but got passthrough")
		}
		if !strings.HasPrefix(token, "Bearer ") {
			t.Errorf("expected Bearer token, got %q", token)
		}
	})

	t.Run("unmatched_host_still_passthrough", func(t *testing.T) {
		p := &processor{}
		headers := buildHeaders("api.openai.com", "Bearer sk-openai-api-key")
		resp := p.handleOutbound(context.Background(), headers)

		if !isPassthrough(resp) {
			t.Error("expected passthrough for unmatched host api.openai.com, but got non-passthrough response")
		}
	})

	t.Run("route_passthrough_explicit", func(t *testing.T) {
		p := &processor{}
		headers := buildHeaders("otel-collector.kagenti-system.svc.cluster.local", "")
		resp := p.handleOutbound(context.Background(), headers)

		if !isPassthrough(resp) {
			t.Error("expected passthrough for otel-collector (explicit passthrough route), but got non-passthrough response")
		}
	})
}

// TestOutboundPolicyRouteMatchExchangeFails verifies that when a route matches but
// Keycloak returns an error, the proxy returns 503 (not passthrough).
func TestOutboundPolicyRouteMatchExchangeFails(t *testing.T) {
	saved := saveGlobals()
	defer restoreGlobals(saved)

	keycloak := mockKeycloak(t, http.StatusBadRequest, map[string]string{
		"error":             "invalid_request",
		"error_description": "Invalid token",
	})
	defer keycloak.Close()

	routesYAML := fmt.Sprintf(`
- host: "github-issue-tool-headless.team1.svc.cluster.local"
  target_audience: "github-tool"
  token_scopes: "openid github-tool-aud"
  token_url: %q
`, keycloak.URL)

	defaultOutboundPolicy = "passthrough"
	globalResolver = setupTestResolver(t, routesYAML)
	setGlobalConfig("test-client", "test-secret", keycloak.URL, "", "")

	p := &processor{}
	headers := buildHeaders("github-issue-tool-headless.team1.svc.cluster.local", "Bearer some-invalid-jwt")
	resp := p.handleOutbound(context.Background(), headers)

	if !isDenied(resp) {
		t.Error("expected 503 denial when exchange fails for a routed host, but got non-denied response")
	}
}
