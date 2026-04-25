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

	result := s.Auth.HandleOutbound(ctx, authHeader, host)

	switch result.Action {
	case auth.ActionReplaceToken:
		return replaceTokenResponse(result.Token)
	case auth.ActionDeny:
		return denyResponse(typev3.StatusCode_ServiceUnavailable,
			jsonError("token_acquisition_failed", result.DenyReason))
	default:
		return passResponse()
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
