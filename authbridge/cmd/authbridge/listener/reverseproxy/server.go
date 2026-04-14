// Package reverseproxy implements an HTTP reverse proxy listener.
// Inbound requests are validated via auth.HandleInbound before being
// forwarded to a fixed backend.
package reverseproxy

import (
	"encoding/json"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/auth"
)

// Server is an HTTP reverse proxy with inbound JWT validation.
type Server struct {
	Auth    *auth.Auth
	proxy   *httputil.ReverseProxy
	backend string
}

// NewServer creates a reverse proxy that forwards to the given backend URL.
func NewServer(a *auth.Auth, backendURL string) (*Server, error) {
	target, err := url.Parse(backendURL)
	if err != nil {
		return nil, err
	}
	return &Server{
		Auth:    a,
		proxy:   httputil.NewSingleHostReverseProxy(target),
		backend: backendURL,
	}, nil
}

// Handler returns the HTTP handler for the reverse proxy.
func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(s.handleRequest)
}

func (s *Server) handleRequest(w http.ResponseWriter, r *http.Request) {
	result := s.Auth.HandleInbound(r.Context(), r.Header.Get("Authorization"), r.URL.Path, "")

	if result.Action == auth.ActionDeny {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(result.DenyStatus)
		body, _ := json.Marshal(map[string]string{"error": result.DenyReason})
		w.Write(body)
		return
	}

	s.proxy.ServeHTTP(w, r)
}
