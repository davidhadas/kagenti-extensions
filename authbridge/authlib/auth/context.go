package auth

import "context"

type contextKey string

const headersKey contextKey = "extra-headers"

// ContextWithHeaders injects extra headers into the context.
func ContextWithHeaders(ctx context.Context, headers map[string]string) context.Context {
	return context.WithValue(ctx, headersKey, headers)
}

// HeadersFromContext extracts extra headers from the context.
func HeadersFromContext(ctx context.Context) map[string]string {
	if h, ok := ctx.Value(headersKey).(map[string]string); ok {
		return h
	}
	return nil
}

// Made with Bob
