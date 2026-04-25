package auth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/bypass"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/cache"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/exchange"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/routing"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/tokenbroker"
	"github.com/kagenti/kagenti-extensions/authbridge/authlib/validation"
)

// mockVerifier captures the audience arg and returns configured claims/error.
type mockVerifier struct {
	claims       *validation.Claims
	err          error
	lastAudience string
}

func (m *mockVerifier) Verify(_ context.Context, _ string, audience string) (*validation.Claims, error) {
	m.lastAudience = audience
	return m.claims, m.err
}

func validClaims() *validation.Claims {
	return &validation.Claims{
		Subject:  "user-123",
		Issuer:   "http://keycloak/realms/test",
		Audience: []string{"my-agent"},
		ClientID: "caller-app",
		Scopes:   []string{"openid"},
	}
}

// --- Inbound Tests ---

func TestHandleInbound_BypassPath(t *testing.T) {
	m, _ := bypass.NewMatcher(bypass.DefaultPatterns)
	a := New(Config{Bypass: m, Verifier: &mockVerifier{claims: validClaims()}})
	result := a.HandleInbound(context.Background(), "", "/healthz", "")
	if result.Action != ActionAllow {
		t.Errorf("expected allow for bypass path, got %s", result.Action)
	}
}

func TestHandleInbound_MissingAuth(t *testing.T) {
	a := New(Config{Verifier: &mockVerifier{}})
	result := a.HandleInbound(context.Background(), "", "/api/test", "")
	if result.Action != ActionDeny || result.DenyStatus != http.StatusUnauthorized {
		t.Errorf("expected deny/401, got %s/%d", result.Action, result.DenyStatus)
	}
}

func TestHandleInbound_InvalidFormat(t *testing.T) {
	a := New(Config{Verifier: &mockVerifier{}})
	result := a.HandleInbound(context.Background(), "Basic abc123", "/api/test", "")
	if result.Action != ActionDeny {
		t.Errorf("expected deny for non-Bearer auth, got %s", result.Action)
	}
}

func TestHandleInbound_CaseInsensitiveBearer(t *testing.T) {
	a := New(Config{
		Verifier: &mockVerifier{claims: validClaims()},
		Identity: IdentityConfig{Audience: "my-agent"},
	})
	// RFC 7235: auth scheme is case-insensitive
	for _, header := range []string{"Bearer token", "bearer token", "BEARER token", "beArer token"} {
		result := a.HandleInbound(context.Background(), header, "/api/test", "")
		if result.Action != ActionAllow {
			t.Errorf("expected allow for %q, got %s: %s", header, result.Action, result.DenyReason)
		}
	}
}

func TestHandleInbound_ValidJWT(t *testing.T) {
	a := New(Config{
		Verifier: &mockVerifier{claims: validClaims()},
		Identity: IdentityConfig{Audience: "my-agent"},
	})
	result := a.HandleInbound(context.Background(), "Bearer valid-token", "/api/test", "")
	if result.Action != ActionAllow {
		t.Errorf("expected allow, got %s: %s", result.Action, result.DenyReason)
	}
	if result.Claims == nil || result.Claims.Subject != "user-123" {
		t.Error("expected claims with subject user-123")
	}
}

func TestHandleInbound_InvalidJWT(t *testing.T) {
	a := New(Config{
		Verifier: &mockVerifier{err: fmt.Errorf("token expired")},
		Identity: IdentityConfig{Audience: "my-agent"},
	})
	result := a.HandleInbound(context.Background(), "Bearer expired-token", "/api/test", "")
	if result.Action != ActionDeny || result.DenyStatus != http.StatusUnauthorized {
		t.Errorf("expected deny/401, got %s/%d", result.Action, result.DenyStatus)
	}
}

func TestHandleInbound_NoVerifier_Denies(t *testing.T) {
	a := New(Config{}) // no verifier = fail-closed
	result := a.HandleInbound(context.Background(), "Bearer some-token", "/api/test", "")
	if result.Action != ActionDeny {
		t.Errorf("expected deny when verifier not configured, got %s", result.Action)
	}
}

func TestHandleInbound_AudienceOverride(t *testing.T) {
	mv := &mockVerifier{claims: validClaims()}
	a := New(Config{
		Verifier: mv,
		Identity: IdentityConfig{Audience: "default-aud"},
	})

	// Empty audience uses default
	a.HandleInbound(context.Background(), "Bearer t", "/api", "")
	if mv.lastAudience != "default-aud" {
		t.Errorf("expected default-aud, got %q", mv.lastAudience)
	}

	// Explicit audience overrides default (waypoint mode)
	a.HandleInbound(context.Background(), "Bearer t", "/api", "derived-from-host")
	if mv.lastAudience != "derived-from-host" {
		t.Errorf("expected derived-from-host, got %q", mv.lastAudience)
	}
}

// --- Outbound Tests ---

func newTestExchangeServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "exchanged-" + r.FormValue("audience"),
			"token_type":   "Bearer",
			"expires_in":   300,
		})
	}))
}

func TestHandleOutbound_NoRouter(t *testing.T) {
	a := New(Config{})
	result := a.HandleOutbound(context.Background(), "Bearer token", "some-host")
	if result.Action != ActionAllow {
		t.Errorf("expected allow with no router, got %s", result.Action)
	}
}

func TestHandleOutbound_PassthroughRoute(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "", []routing.Route{
		{Host: "internal-svc", Action: "passthrough"},
	})
	a := New(Config{Router: router})
	result := a.HandleOutbound(context.Background(), "Bearer token", "internal-svc")
	if result.Action != ActionAllow {
		t.Errorf("expected allow for passthrough route, got %s", result.Action)
	}
}

func TestHandleOutbound_NoMatch_Passthrough(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "", []routing.Route{
		{Host: "known-svc", Audience: "known"},
	})
	a := New(Config{Router: router})
	result := a.HandleOutbound(context.Background(), "Bearer token", "unknown-svc")
	if result.Action != ActionAllow {
		t.Errorf("expected allow for unmatched host with passthrough default, got %s", result.Action)
	}
}

func TestHandleOutbound_Exchange(t *testing.T) {
	srv := newTestExchangeServer(t)
	defer srv.Close()

	router, _ := routing.NewRouter("passthrough", "", []routing.Route{
		{Host: "target-svc", Audience: "target-aud", Scopes: "openid"},
	})
	exchanger := exchange.NewClient(srv.URL, &exchange.ClientSecretAuth{
		ClientID: "agent", ClientSecret: "secret",
	})
	a := New(Config{
		Router:    router,
		Exchanger: exchanger,
		Cache:     cache.New(),
	})

	result := a.HandleOutbound(context.Background(), "Bearer user-token", "target-svc")
	if result.Action != ActionReplaceToken {
		t.Fatalf("expected replace_token, got %s: %s", result.Action, result.DenyReason)
	}
	if result.Token != "exchanged-target-aud" {
		t.Errorf("token = %q, want %q", result.Token, "exchanged-target-aud")
	}
}

func TestHandleOutbound_CacheHit(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "", []routing.Route{
		{Host: "target-svc", Audience: "target-aud"},
	})
	c := cache.New()
	c.Set("user-token", "target-aud", "cached-token", 5*time.Minute)

	a := New(Config{Router: router, Cache: c})

	result := a.HandleOutbound(context.Background(), "Bearer user-token", "target-svc")
	if result.Action != ActionReplaceToken || result.Token != "cached-token" {
		t.Errorf("expected cached token, got action=%s token=%q", result.Action, result.Token)
	}
}

func TestHandleOutbound_NoToken_ClientCredentials(t *testing.T) {
	srv := newTestExchangeServer(t)
	defer srv.Close()

	router, _ := routing.NewRouter("exchange", "", []routing.Route{})
	exchanger := exchange.NewClient(srv.URL, &exchange.ClientSecretAuth{
		ClientID: "agent", ClientSecret: "secret",
	})
	a := New(Config{
		Router:        router,
		Exchanger:     exchanger,
		NoTokenPolicy: NoTokenPolicyClientCredentials,
	})

	result := a.HandleOutbound(context.Background(), "", "any-svc")
	if result.Action != ActionReplaceToken {
		t.Fatalf("expected replace_token from client_credentials, got %s: %s", result.Action, result.DenyReason)
	}
}

func TestHandleOutbound_NoToken_Allow(t *testing.T) {
	router, _ := routing.NewRouter("exchange", "", []routing.Route{})
	a := New(Config{
		Router:        router,
		NoTokenPolicy: NoTokenPolicyAllow,
	})

	result := a.HandleOutbound(context.Background(), "", "any-svc")
	if result.Action != ActionAllow {
		t.Errorf("expected allow for no-token allow policy, got %s", result.Action)
	}
}

func TestHandleOutbound_NoToken_Deny(t *testing.T) {
	router, _ := routing.NewRouter("exchange", "", []routing.Route{})
	a := New(Config{
		Router:        router,
		NoTokenPolicy: NoTokenPolicyDeny,
	})

	result := a.HandleOutbound(context.Background(), "", "any-svc")
	if result.Action != ActionDeny {
		t.Errorf("expected deny for no-token deny policy, got %s", result.Action)
	}
}

func TestHandleOutbound_PerRouteTokenEndpoint(t *testing.T) {
	// Main server should NOT be called
	mainSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("main token URL should not be called when route overrides it")
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer mainSrv.Close()

	// Per-route server SHOULD be called
	routeSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "from-route-endpoint",
			"token_type":   "Bearer",
			"expires_in":   300,
		})
	}))
	defer routeSrv.Close()

	router, _ := routing.NewRouter("passthrough", "", []routing.Route{
		{Host: "custom-svc", Audience: "custom-aud", TokenEndpoint: routeSrv.URL},
	})
	exchanger := exchange.NewClient(mainSrv.URL, &exchange.ClientSecretAuth{
		ClientID: "agent", ClientSecret: "secret",
	})
	a := New(Config{Router: router, Exchanger: exchanger})

	result := a.HandleOutbound(context.Background(), "Bearer token", "custom-svc")
	if result.Action != ActionReplaceToken || result.Token != "from-route-endpoint" {
		t.Errorf("expected token from route endpoint, got action=%s token=%q", result.Action, result.Token)
	}
}

func TestHandleOutbound_ActorToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if got := r.FormValue("actor_token"); got != "actor-jwt" {
			t.Errorf("actor_token = %q, want actor-jwt", got)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "delegated",
			"token_type":   "Bearer",
			"expires_in":   300,
		})
	}))
	defer srv.Close()

	router, _ := routing.NewRouter("exchange", "", []routing.Route{})
	exchanger := exchange.NewClient(srv.URL, &exchange.ClientSecretAuth{
		ClientID: "agent", ClientSecret: "secret",
	})
	a := New(Config{
		Router:    router,
		Exchanger: exchanger,
		ActorTokenSource: func(_ context.Context) (string, error) {
			return "actor-jwt", nil
		},
	})

	result := a.HandleOutbound(context.Background(), "Bearer user-token", "any-svc")
	if result.Action != ActionReplaceToken || result.Token != "delegated" {
		t.Errorf("expected delegated token, got action=%s token=%q", result.Action, result.Token)
	}
}

// --- JWT Helper Function Tests ---

func createTestJWT(jti, sub, preferredUsername string) string {
	// Create a simple JWT with the claims we need
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))

	claims := map[string]string{
		"jti": jti,
		"sub": sub,
	}
	if preferredUsername != "" {
		claims["preferred_username"] = preferredUsername
	}

	claimsJSON, _ := json.Marshal(claims)
	payload := base64.RawURLEncoding.EncodeToString(claimsJSON)

	// We don't need a real signature for these tests
	signature := base64.RawURLEncoding.EncodeToString([]byte("fake-signature"))

	return fmt.Sprintf("%s.%s.%s", header, payload, signature)
}

func TestExtractJWTClaims(t *testing.T) {
	tests := []struct {
		name    string
		token   string
		wantJTI string
		wantSub string
		wantErr bool
	}{
		{
			name:    "valid token with all claims",
			token:   createTestJWT("onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647", "user-123", "alice"),
			wantJTI: "onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
			wantSub: "user-123",
			wantErr: false,
		},
		{
			name:    "token without preferred_username",
			token:   createTestJWT("session-456", "bob", ""),
			wantJTI: "session-456",
			wantSub: "bob",
			wantErr: false,
		},
		{
			name:    "invalid token format",
			token:   "not.a.valid.jwt.token",
			wantErr: true,
		},
		{
			name:    "token with only two parts",
			token:   "header.payload",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			claims, err := extractJWTClaims(tt.token)
			if (err != nil) != tt.wantErr {
				t.Errorf("extractJWTClaims() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr {
				if claims.JTI != tt.wantJTI {
					t.Errorf("JTI = %q, want %q", claims.JTI, tt.wantJTI)
				}
				if claims.Sub != tt.wantSub {
					t.Errorf("Sub = %q, want %q", claims.Sub, tt.wantSub)
				}
			}
		})
	}
}

func TestGetUserID(t *testing.T) {
	tests := []struct {
		name              string
		preferredUsername string
		sub               string
		want              string
	}{
		{
			name:              "prefers preferred_username",
			preferredUsername: "alice",
			sub:               "123e4567-e89b-12d3-a456-426614174000",
			want:              "alice",
		},
		{
			name:              "falls back to sub when preferred_username empty",
			preferredUsername: "",
			sub:               "123e4567-e89b-12d3-a456-426614174000",
			want:              "123e4567-e89b-12d3-a456-426614174000",
		},
		{
			name:              "uses sub when both present",
			preferredUsername: "",
			sub:               "bob",
			want:              "bob",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			claims := &jwtClaims{
				PreferredUsername: tt.preferredUsername,
				Sub:               tt.sub,
			}
			got := getUserID(claims)
			if got != tt.want {
				t.Errorf("getUserID() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestExtractUUIDFromJTI(t *testing.T) {
	tests := []struct {
		name string
		jti  string
		want string
	}{
		{
			name: "keycloak format with prefix",
			jti:  "onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
			want: "8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
		},
		{
			name: "already a UUID",
			jti:  "8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
			want: "8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
		},
		{
			name: "multiple colons - takes last",
			jti:  "realm:client:8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
			want: "8ae0e5d0-a74a-7cf7-4f5e-64276681e647",
		},
		{
			name: "empty string",
			jti:  "",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractUUIDFromJTI(tt.jti)
			if got != tt.want {
				t.Errorf("extractUUIDFromJTI() = %q, want %q", got, tt.want)
			}
		})
	}
}

// --- Broker Route Tests ---

// Note: Broker route tests are simplified since we need to test through the router
// which resolves routes and sets TokenBrokerURL in ResolvedRoute.
// The key functionality we're testing is JWT claim extraction in handleBroker.

func TestHandleOutbound_BrokerRoute_Success(t *testing.T) {
	// Create a test JWT token with Keycloak-style jti
	jwtToken := createTestJWT("onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647", "user-123", "alice")

	// Create mock token broker server
	var capturedToken string
	brokerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the endpoint is /token
		if r.URL.Path != "/token" {
			t.Errorf("unexpected path: %s, want /token", r.URL.Path)
		}

		// Extract token from Authorization header
		authHeader := r.Header.Get("Authorization")
		capturedToken = strings.TrimPrefix(authHeader, "Bearer ")

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"token": "broker-token-123"})
	}))
	defer brokerSrv.Close()

	// Setup routing with broker route
	// Note: Router will set TokenBrokerURL in ResolvedRoute based on config
	router, _ := routing.NewRouter("passthrough", brokerSrv.URL, []routing.Route{
		{Host: "mcp-server", Action: "broker"},
	})

	a := New(Config{
		Router:            router,
		TokenBrokerClient: tokenbroker.NewClient(),
	})

	// Create context with headers including Authorization
	ctx := ContextWithHeaders(context.Background(), map[string]string{
		"authorization": "Bearer " + jwtToken,
	})

	result := a.HandleOutbound(ctx, "Bearer "+jwtToken, "mcp-server")

	if result.Action != ActionReplaceToken {
		t.Errorf("expected ActionReplaceToken, got %s: %s", result.Action, result.DenyReason)
	}
	if result.Token != "broker-token-123" {
		t.Errorf("token = %q, want %q", result.Token, "broker-token-123")
	}
	// Verify the token was sent to the broker
	if capturedToken != jwtToken {
		t.Errorf("captured token = %q, want %q", capturedToken, jwtToken)
	}
}

func TestHandleOutbound_BrokerRoute_MissingAuthHeader(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "http://broker", []routing.Route{
		{Host: "mcp-server", Action: "broker"},
	})

	a := New(Config{
		Router:            router,
		TokenBrokerClient: tokenbroker.NewClient(),
	})

	// Context without Authorization header
	ctx := ContextWithHeaders(context.Background(), map[string]string{})

	result := a.HandleOutbound(ctx, "", "mcp-server")

	if result.Action != ActionDeny {
		t.Errorf("expected ActionDeny, got %s", result.Action)
	}
	if result.DenyStatus != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", result.DenyStatus)
	}
}

func TestHandleOutbound_BrokerRoute_InvalidJWT(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "http://broker", []routing.Route{
		{Host: "mcp-server", Action: "broker"},
	})

	a := New(Config{
		Router:            router,
		TokenBrokerClient: tokenbroker.NewClient(),
	})

	// Context with invalid JWT
	ctx := ContextWithHeaders(context.Background(), map[string]string{
		"authorization": "Bearer invalid.jwt",
	})

	result := a.HandleOutbound(ctx, "Bearer invalid.jwt", "mcp-server")

	if result.Action != ActionDeny {
		t.Errorf("expected ActionDeny, got %s", result.Action)
	}
	// Now expects 403 because the broker call fails (not 401 for invalid JWT)
	if result.DenyStatus != http.StatusForbidden {
		t.Errorf("expected status 403, got %d", result.DenyStatus)
	}
}

func TestHandleOutbound_BrokerRoute_NoBrokerClient(t *testing.T) {
	router, _ := routing.NewRouter("passthrough", "http://broker", []routing.Route{
		{Host: "mcp-server", Action: "broker"},
	})

	// No token broker client configured
	a := New(Config{
		Router: router,
	})

	jwtToken := createTestJWT("session:123", "user-456", "bob")
	ctx := ContextWithHeaders(context.Background(), map[string]string{
		"authorization": "Bearer " + jwtToken,
	})

	result := a.HandleOutbound(ctx, "Bearer "+jwtToken, "mcp-server")

	if result.Action != ActionDeny {
		t.Errorf("expected ActionDeny, got %s", result.Action)
	}
	if result.DenyStatus != http.StatusServiceUnavailable {
		t.Errorf("expected status 503, got %d", result.DenyStatus)
	}
}

func TestHandleOutbound_BrokerRoute_FallbackToSub(t *testing.T) {
	// Create JWT without preferred_username - should fall back to sub
	jwtToken := createTestJWT("prefix:uuid-789", "fallback-user", "")

	// Create mock token broker server
	var capturedToken string
	brokerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the endpoint is /token
		if r.URL.Path != "/token" {
			t.Errorf("unexpected path: %s, want /token", r.URL.Path)
		}

		// Extract token from Authorization header
		authHeader := r.Header.Get("Authorization")
		capturedToken = strings.TrimPrefix(authHeader, "Bearer ")

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"token": "broker-token-456"})
	}))
	defer brokerSrv.Close()

	router, _ := routing.NewRouter("passthrough", brokerSrv.URL, []routing.Route{
		{Host: "mcp-server", Action: "broker"},
	})

	a := New(Config{
		Router:            router,
		TokenBrokerClient: tokenbroker.NewClient(),
	})

	ctx := ContextWithHeaders(context.Background(), map[string]string{
		"authorization": "Bearer " + jwtToken,
	})

	result := a.HandleOutbound(ctx, "Bearer "+jwtToken, "mcp-server")

	if result.Action != ActionReplaceToken {
		t.Errorf("expected ActionReplaceToken, got %s: %s", result.Action, result.DenyReason)
	}

	// Verify the token was sent to the broker
	if capturedToken != jwtToken {
		t.Errorf("captured token = %q, want %q", capturedToken, jwtToken)
	}
}
