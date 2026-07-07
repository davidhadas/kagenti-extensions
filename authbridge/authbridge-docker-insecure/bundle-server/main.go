// Bundle server for authbridge-compose.
//
// Serves OPA policy bundles over HTTP so the authbridge opa plugin can
// download them at startup and poll for updates.
//
//	GET /bundles?spiffe=<agent-id>  →  bundle.tar.gz  (ETag / 304 supported)
//	GET /healthz
//	GET /readyz
//
// Bundle layout on disk (mounted at POLICY_DIR, default /policies):
//
//	/policies/
//	  outbound/
//	    request.rego      (package authbridge.outbound.request)
//	  inbound/
//	    request.rego      (package authbridge.inbound.request, optional)
//
// All .rego files are served to every agent (same default bundle).
// The spiffe query parameter is logged but not used for routing; extend
// loadPolicies if you need per-agent policy differentiation.
//
// Uses the bundle builder from kagenti-operator (bundle/builder.go,
// bundle/hash.go) — copied under internal/bundle/ — so the tar+gzip
// format and .manifest file match what the operator serves in-cluster.
package main

import (
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"authbridge-compose/bundle-server/internal/bundle"
)

// cachedBundle holds the last-built bundle so repeated requests for the
// same unchanged policy dir are served from memory (no disk re-scan).
type cachedBundle struct {
	mu   sync.RWMutex
	data []byte
	etag string
	// built is when the bundle was last built from disk.
	built time.Time
}

var cached cachedBundle

const bundleTTL = 30 * time.Second

func main() {
	policyDir := os.Getenv("POLICY_DIR")
	if policyDir == "" {
		policyDir = "/policies"
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8090"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/bundles", func(w http.ResponseWriter, r *http.Request) {
		agentID := r.URL.Query().Get("spiffe")
		slog.Info("bundle request", "agent_id", agentID, "remote", r.RemoteAddr)

		data, etag, err := getBundle(policyDir)
		if err != nil {
			slog.Error("bundle build failed", "error", err)
			http.Error(w, "bundle unavailable", http.StatusInternalServerError)
			return
		}

		// ETag-based conditional GET (strip surrounding quotes from client).
		ifNoneMatch := strings.Trim(r.Header.Get("If-None-Match"), `"`)
		if ifNoneMatch != "" && ifNoneMatch == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}

		w.Header().Set("Content-Type", "application/gzip")
		w.Header().Set("ETag", `"`+etag+`"`)
		w.Header().Set("Cache-Control", "max-age=0, must-revalidate")
		_, _ = w.Write(data)
		slog.Info("bundle served", "agent_id", agentID, "etag", etag, "bytes", len(data))
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		// Ready once we can build at least one bundle.
		if _, _, err := getBundle(policyDir); err != nil {
			http.Error(w, "not ready: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	slog.Info("bundle-server starting", "addr", addr, "policy_dir", policyDir)
	if err := http.ListenAndServe(addr, mux); err != nil {
		slog.Error("bundle-server exiting", "error", err)
		os.Exit(1)
	}
}

// getBundle returns a cached bundle, rebuilding it from disk when the TTL
// has expired. Thread-safe.
func getBundle(policyDir string) ([]byte, string, error) {
	cached.mu.RLock()
	if cached.data != nil && time.Since(cached.built) < bundleTTL {
		data, etag := cached.data, cached.etag
		cached.mu.RUnlock()
		return data, etag, nil
	}
	cached.mu.RUnlock()

	// Rebuild under write lock.
	cached.mu.Lock()
	defer cached.mu.Unlock()
	// Double-check after acquiring write lock.
	if cached.data != nil && time.Since(cached.built) < bundleTTL {
		return cached.data, cached.etag, nil
	}

	policies, err := loadPolicies(policyDir)
	if err != nil {
		return nil, "", err
	}
	data, etag, err := bundle.Build(policies)
	if err != nil {
		return nil, "", err
	}
	cached.data = data
	cached.etag = etag
	cached.built = time.Now()
	slog.Info("bundle rebuilt from disk", "policies", len(policies), "etag", etag)
	return data, etag, nil
}

// loadPolicies walks policyDir and returns one Policy per .rego file.
// The archive path is relative to policyDir, matching the OPA bundle spec.
func loadPolicies(dir string) ([]bundle.Policy, error) {
	var policies []bundle.Policy
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".rego") {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		policies = append(policies, bundle.Policy{Path: rel, Content: string(content)})
		return nil
	})
	return policies, err
}
