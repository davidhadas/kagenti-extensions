// Package forwardproxy implements an HTTP forward proxy listener.
// Agents set HTTP_PROXY to route outbound traffic through this proxy
// for transparent token exchange.
package forwardproxy

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/auth"
)

// Server is an HTTP forward proxy that performs token exchange on outbound requests.
type Server struct {
	Auth   *auth.Auth
	Client *http.Client
}

// NewServer creates a forward proxy server with a default HTTP client.
func NewServer(a *auth.Auth) *Server {
	return &Server{
		Auth: a,
		Client: &http.Client{
			Timeout: 30 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// Handler returns the HTTP handler for the forward proxy.
func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(s.handleRequest)
}

func (s *Server) handleRequest(w http.ResponseWriter, r *http.Request) {
	// Reject CONNECT (HTTPS tunneling) — only handle plain HTTP
	if r.Method == http.MethodConnect {
		http.Error(w, `{"error":"HTTPS CONNECT not supported — only HTTP proxy"}`, http.StatusMethodNotAllowed)
		return
	}

	result := s.Auth.HandleOutbound(r.Context(), r.Header.Get("Authorization"), r.Host)

	switch result.Action {
	case auth.ActionDeny:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(result.DenyStatus)
		body, _ := json.Marshal(map[string]string{"error": result.DenyReason})
		w.Write(body)
		return
	case auth.ActionReplaceToken:
		r.Header.Set("Authorization", "Bearer "+result.Token)
	}

	// Remove hop-by-hop headers
	r.Header.Del("Connection")
	r.Header.Del("Keep-Alive")
	r.Header.Del("Proxy-Authenticate")
	r.Header.Del("Proxy-Authorization")
	r.Header.Del("Proxy-Connection")
	r.Header.Del("TE")
	r.Header.Del("Trailer")
	r.Header.Del("Transfer-Encoding")
	r.Header.Del("Upgrade")

	// Clear RequestURI — set by the server but must be empty for client requests
	r.RequestURI = ""

	resp, err := s.Client.Do(r)
	if err != nil {
		http.Error(w, `{"error":"bad gateway"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	if _, err := io.Copy(w, resp.Body); err != nil {
		slog.Debug("response copy error", "host", r.Host, "error", err)
	}
}
