// Package tokenbroker provides an HTTP client for the Token Broker service.
package tokenbroker

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client is an HTTP client for the Token Broker service.
type Client struct {
	httpClient *http.Client
}

// NewClient creates a new Token Broker client.
func NewClient() *Client {
	return &Client{
		httpClient: &http.Client{
			Timeout: 310 * time.Second, // Longer than Token Broker's 300s timeout
		},
	}
}

// AcquireToken calls the Token Broker to get a token for the given session, user, and MCP server.
// Blocks until a token is available or the context is cancelled.
func (c *Client) AcquireToken(ctx context.Context, tokenBrokerURL, sessionKey, userID, mcpServerURL string) (string, error) {
	url := fmt.Sprintf("%s/sessions/%s/token", tokenBrokerURL, sessionKey)

	req, err := http.NewRequestWithContext(ctx, "POST", url, nil)
	if err != nil {
		return "", fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-Mcp-Server-Url", mcpServerURL)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("token broker request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token broker returned %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("parsing token response: %w", err)
	}

	return result.Token, nil
}

// Made with Bob
