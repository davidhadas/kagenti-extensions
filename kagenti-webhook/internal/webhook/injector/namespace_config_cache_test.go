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
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestNamespaceConfigCache_GetOrLoad_CacheHit(t *testing.T) {
	envCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: EnvironmentsConfigMapName, Namespace: "ns1"},
		Data:       map[string]string{"KEYCLOAK_URL": "http://keycloak:8080"},
	}
	reader := newFakeReader(envCM)
	cache := NewNamespaceConfigCache()

	ctx := context.Background()

	// First call — cache miss, reads from API
	cfg1, err := cache.GetOrLoad(ctx, reader, "ns1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg1.KeycloakURL != "http://keycloak:8080" {
		t.Errorf("KeycloakURL = %q", cfg1.KeycloakURL)
	}

	// Second call — cache hit, same pointer
	cfg2, err := cache.GetOrLoad(ctx, reader, "ns1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg1 != cfg2 {
		t.Error("expected same pointer from cache hit")
	}
}

func TestNamespaceConfigCache_GetOrLoad_DifferentNamespaces(t *testing.T) {
	envCM1 := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: EnvironmentsConfigMapName, Namespace: "ns1"},
		Data:       map[string]string{"KEYCLOAK_URL": "http://keycloak-ns1:8080"},
	}
	envCM2 := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: EnvironmentsConfigMapName, Namespace: "ns2"},
		Data:       map[string]string{"KEYCLOAK_URL": "http://keycloak-ns2:8080"},
	}
	reader := newFakeReader(envCM1, envCM2)
	cache := NewNamespaceConfigCache()

	ctx := context.Background()

	cfg1, _ := cache.GetOrLoad(ctx, reader, "ns1")
	cfg2, _ := cache.GetOrLoad(ctx, reader, "ns2")

	if cfg1.KeycloakURL != "http://keycloak-ns1:8080" {
		t.Errorf("ns1 KeycloakURL = %q", cfg1.KeycloakURL)
	}
	if cfg2.KeycloakURL != "http://keycloak-ns2:8080" {
		t.Errorf("ns2 KeycloakURL = %q", cfg2.KeycloakURL)
	}
}

func TestNamespaceConfigCache_GetOrLoad_EmptyNamespace(t *testing.T) {
	reader := newFakeReader() // no objects
	cache := NewNamespaceConfigCache()

	cfg, err := cache.GetOrLoad(context.Background(), reader, "empty-ns")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.KeycloakURL != "" {
		t.Errorf("expected empty KeycloakURL, got %q", cfg.KeycloakURL)
	}

	// Second call should still return cached empty config
	cfg2, _ := cache.GetOrLoad(context.Background(), reader, "empty-ns")
	if cfg != cfg2 {
		t.Error("expected same pointer from cache hit for empty namespace")
	}
}
