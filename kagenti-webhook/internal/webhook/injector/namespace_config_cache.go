/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package injector

import (
	"context"
	"sync"

	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

var cacheLog = logf.Log.WithName("namespace-config-cache")

// NamespaceConfigCache provides thread-safe per-namespace caching of
// NamespaceConfig values. When the cache has an entry for a namespace, it is
// returned without hitting the API server. The cache lives in memory and is
// cleared on webhook pod restart.
type NamespaceConfigCache struct {
	mu    sync.RWMutex
	store map[string]*NamespaceConfig
}

// NewNamespaceConfigCache creates an empty cache.
func NewNamespaceConfigCache() *NamespaceConfigCache {
	return &NamespaceConfigCache{
		store: make(map[string]*NamespaceConfig),
	}
}

// GetOrLoad returns the cached NamespaceConfig for the given namespace. If no
// entry exists, it reads from the API server via ReadNamespaceConfig, stores
// the result, and returns it.
func (c *NamespaceConfigCache) GetOrLoad(ctx context.Context, reader client.Reader, namespace string) (*NamespaceConfig, error) {
	// Fast path: read lock
	c.mu.RLock()
	if cfg, ok := c.store[namespace]; ok {
		c.mu.RUnlock()
		cacheLog.V(2).Info("namespace config cache hit", "namespace", namespace)
		return cfg, nil
	}
	c.mu.RUnlock()

	// Slow path: read from API server, then store
	cfg, err := ReadNamespaceConfig(ctx, reader, namespace)
	if err != nil {
		return nil, err
	}

	c.mu.Lock()
	// Double-check — another goroutine may have populated it
	if existing, ok := c.store[namespace]; ok {
		c.mu.Unlock()
		return existing, nil
	}
	c.store[namespace] = cfg
	c.mu.Unlock()

	cacheLog.Info("namespace config cached", "namespace", namespace)
	return cfg, nil
}
