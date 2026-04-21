// Package extproc implements an Envoy ext_proc gRPC streaming listener.
// It translates ext_proc ProcessingRequests into auth.HandleInbound/HandleOutbound
// calls and maps the results back to ProcessingResponses.
package extproc

import (
	"context"
	"encoding/json"
	"strings"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/kagenti/kagenti-extensions/authbridge/authlib/auth"
)

// Server implements the Envoy ext_proc ExternalProcessor gRPC service.
type Server struct {
	extprocv3.UnimplementedExternalProcessorServer
	Auth *auth.Auth
}

// Process handles the bidirectional ext_proc stream.
func (s *Server) Process(stream extprocv3.ExternalProcessor_ProcessServer) error {
	ctx := stream.Context()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		req, err := stream.Recv()
		if err != nil {
			return status.Errorf(codes.Unknown, "cannot receive stream request: %v", err)
		}

		var resp *extprocv3.ProcessingResponse

		switch r := req.Request.(type) {
		case *extprocv3.ProcessingRequest_RequestHeaders:
			headers := r.RequestHeaders.Headers
			direction := getHeader(headers, "x-authbridge-direction")

			if direction == "inbound" {
				resp = s.handleInbound(ctx, headers)
			} else {
				resp = s.handleOutbound(ctx, headers)
			}

		case *extprocv3.ProcessingRequest_ResponseHeaders:
			resp = &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseHeaders{
					ResponseHeaders: &extprocv3.HeadersResponse{},
				},
			}

		default:
			resp = &extprocv3.ProcessingResponse{}
		}

		if err := stream.Send(resp); err != nil {
			return status.Errorf(codes.Unknown, "cannot send stream response: %v", err)
		}
	}
}

func (s *Server) handleInbound(ctx context.Context, headers *corev3.HeaderMap) *extprocv3.ProcessingResponse {
	authHeader := getHeader(headers, "authorization")
	path := getHeader(headers, ":path")

	result := s.Auth.HandleInbound(ctx, authHeader, path, "")

	if result.Action == auth.ActionDeny {
		return denyResponse(typev3.StatusCode_Unauthorized,
			jsonError("unauthorized", result.DenyReason))
	}

	return allowResponse()
}

func (s *Server) handleOutbound(ctx context.Context, headers *corev3.HeaderMap) *extprocv3.ProcessingResponse {
	authHeader := getHeader(headers, "authorization")
	host := getHeader(headers, ":authority")
	if host == "" {
		host = getHeader(headers, "host")
	}

	// Extract broker route headers and inject into context
	extraHeaders := make(map[string]string)
	if sessionKey := getHeader(headers, "x-oauth-session-key"); sessionKey != "" {
		extraHeaders["x-oauth-session-key"] = sessionKey
	}
	if userID := getHeader(headers, "x-user-id"); userID != "" {
		extraHeaders["x-user-id"] = userID
	}
	if mcpServerURL := getHeader(headers, "x-mcp-server-url"); mcpServerURL != "" {
		extraHeaders["x-mcp-server-url"] = mcpServerURL
	}

	// Inject headers into context
	if len(extraHeaders) > 0 {
		ctx = auth.ContextWithHeaders(ctx, extraHeaders)
	}

	result := s.Auth.HandleOutbound(ctx, authHeader, host)

	// Internal Kagenti headers to strip before forwarding upstream
	headersToRemove := []string{"x-oauth-session-key", "x-user-id", "x-mcp-server-url"}

	switch result.Action {
	case auth.ActionReplaceToken:
		return replaceTokenAndStripHeadersResponse(result.Token, headersToRemove)
	case auth.ActionDeny:
		if result.Broker {
			return denyResponse(typev3.StatusCode_Forbidden, mcpJSONRPCError(result.DenyReason))
		}
		return denyResponse(typev3.StatusCode_ServiceUnavailable,
			jsonError("token_acquisition_failed", result.DenyReason))
	default:
		return passAndStripHeadersResponse(headersToRemove)
	}
}

func allowResponse() *extprocv3.ProcessingResponse {
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_RequestHeaders{
			RequestHeaders: &extprocv3.HeadersResponse{
				Response: &extprocv3.CommonResponse{
					HeaderMutation: &extprocv3.HeaderMutation{
						RemoveHeaders: []string{"x-authbridge-direction"},
					},
				},
			},
		},
	}
}

func passResponse() *extprocv3.ProcessingResponse {
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_RequestHeaders{
			RequestHeaders: &extprocv3.HeadersResponse{},
		},
	}
}

func replaceTokenResponse(token string) *extprocv3.ProcessingResponse {
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_RequestHeaders{
			RequestHeaders: &extprocv3.HeadersResponse{
				Response: &extprocv3.CommonResponse{
					HeaderMutation: &extprocv3.HeaderMutation{
						SetHeaders: []*corev3.HeaderValueOption{
							{
								Header: &corev3.HeaderValue{
									Key:      "authorization",
									RawValue: []byte("Bearer " + token),
								},
							},
						},
					},
				},
			},
		},
	}
}

func denyResponse(code typev3.StatusCode, body string) *extprocv3.ProcessingResponse {
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_ImmediateResponse{
			ImmediateResponse: &extprocv3.ImmediateResponse{
				Status: &typev3.HttpStatus{Code: code},
				Body:   []byte(body),
			},
		},
	}
}

func jsonError(errorCode, message string) string {
	b, _ := json.Marshal(map[string]string{"error": errorCode, "message": message})
	return string(b)
}

func mcpJSONRPCError(message string) string {
	response := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      nil,
		"error": map[string]interface{}{
			"code":    -32001,
			"message": message,
		},
	}
	b, _ := json.Marshal(response)
	return string(b)
}

func replaceTokenAndStripHeadersResponse(token string, headersToRemove []string) *extprocv3.ProcessingResponse {
	headerMutation := &extprocv3.HeaderMutation{
		SetHeaders: []*corev3.HeaderValueOption{
			{Header: &corev3.HeaderValue{Key: "authorization", RawValue: []byte("Bearer " + token)}},
		},
	}
	for _, h := range headersToRemove {
		headerMutation.RemoveHeaders = append(headerMutation.RemoveHeaders, h)
	}
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_RequestHeaders{
			RequestHeaders: &extprocv3.HeadersResponse{
				Response: &extprocv3.CommonResponse{
					HeaderMutation: headerMutation,
				},
			},
		},
	}
}

func passAndStripHeadersResponse(headersToRemove []string) *extprocv3.ProcessingResponse {
	if len(headersToRemove) == 0 {
		return passResponse()
	}
	headerMutation := &extprocv3.HeaderMutation{}
	for _, h := range headersToRemove {
		headerMutation.RemoveHeaders = append(headerMutation.RemoveHeaders, h)
	}
	return &extprocv3.ProcessingResponse{
		Response: &extprocv3.ProcessingResponse_RequestHeaders{
			RequestHeaders: &extprocv3.HeadersResponse{
				Response: &extprocv3.CommonResponse{
					HeaderMutation: headerMutation,
				},
			},
		},
	}
}

func getHeader(headers *corev3.HeaderMap, key string) string {
	if headers == nil {
		return ""
	}
	for _, h := range headers.Headers {
		if strings.EqualFold(h.Key, key) {
			return string(h.RawValue)
		}
	}
	return ""
}
