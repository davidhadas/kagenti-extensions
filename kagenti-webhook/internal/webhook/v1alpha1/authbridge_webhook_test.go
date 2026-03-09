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

package v1alpha1

import (
	"fmt"

	"github.com/kagenti/kagenti-extensions/kagenti-webhook/internal/webhook/injector"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var testNsCounter int

var _ = Describe("AuthBridge Pod Webhook", func() {
	var testNamespace string

	BeforeEach(func() {
		// Create a unique namespace with kagenti-enabled=true for each test
		testNsCounter++
		testNamespace = fmt.Sprintf("test-webhook-%d", testNsCounter)

		ns := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: testNamespace,
				Labels: map[string]string{
					"kagenti-enabled": "true",
				},
			},
		}
		err := k8sClient.Create(ctx, ns)
		Expect(err).NotTo(HaveOccurred())
	})

	newTestPod := func(name string, labels map[string]string) *corev1.Pod {
		return &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				GenerateName: name + "-",
				Namespace:    testNamespace,
				Labels:       labels,
			},
			Spec: corev1.PodSpec{
				Containers: []corev1.Container{
					{
						Name:  "app",
						Image: "busybox:latest",
					},
				},
			},
		}
	}

	Context("when a Pod has kagenti.io/type=agent and kagenti.io/inject=enabled", func() {
		It("should inject sidecars", func() {
			pod := newTestPod("agent-pod", map[string]string{
				"kagenti.io/type":   "agent",
				"kagenti.io/inject": "enabled",
			})

			err := k8sClient.Create(ctx, pod)
			Expect(err).NotTo(HaveOccurred())

			// Verify sidecars were injected
			Expect(containerNames(pod.Spec.Containers)).To(ContainElement(injector.EnvoyProxyContainerName))
			Expect(initContainerNames(pod.Spec.InitContainers)).To(ContainElement(injector.ProxyInitContainerName))
		})
	})

	Context("when a Pod has kagenti.io/type=tool and kagenti.io/inject=enabled", func() {
		It("should not inject sidecars (injectTools feature gate is disabled by default)", func() {
			pod := newTestPod("tool-pod", map[string]string{
				"kagenti.io/type":   "tool",
				"kagenti.io/inject": "enabled",
			})

			err := k8sClient.Create(ctx, pod)
			Expect(err).NotTo(HaveOccurred())

			Expect(containerNames(pod.Spec.Containers)).NotTo(ContainElement(injector.EnvoyProxyContainerName))
			Expect(initContainerNames(pod.Spec.InitContainers)).NotTo(ContainElement(injector.ProxyInitContainerName))
		})
	})

	Context("when a Pod does not have kagenti.io/type label", func() {
		It("should not inject sidecars", func() {
			pod := newTestPod("no-type-pod", map[string]string{
				"kagenti.io/inject": "enabled",
			})

			err := k8sClient.Create(ctx, pod)
			Expect(err).NotTo(HaveOccurred())

			Expect(containerNames(pod.Spec.Containers)).NotTo(ContainElement(injector.EnvoyProxyContainerName))
			Expect(initContainerNames(pod.Spec.InitContainers)).NotTo(ContainElement(injector.ProxyInitContainerName))
		})
	})

	Context("when a Pod has kagenti.io/inject=disabled", func() {
		It("should not inject sidecars", func() {
			pod := newTestPod("disabled-pod", map[string]string{
				"kagenti.io/type":   "agent",
				"kagenti.io/inject": "disabled",
			})

			err := k8sClient.Create(ctx, pod)
			Expect(err).NotTo(HaveOccurred())

			Expect(containerNames(pod.Spec.Containers)).NotTo(ContainElement(injector.EnvoyProxyContainerName))
			Expect(initContainerNames(pod.Spec.InitContainers)).NotTo(ContainElement(injector.ProxyInitContainerName))
		})
	})

	Context("when a Pod already has injected containers (idempotency)", func() {
		It("should not double-inject", func() {
			pod := newTestPod("already-injected-pod", map[string]string{
				"kagenti.io/type":   "agent",
				"kagenti.io/inject": "enabled",
			})
			// Pre-add the envoy-proxy container to simulate prior injection
			pod.Spec.Containers = append(pod.Spec.Containers, corev1.Container{
				Name:  injector.EnvoyProxyContainerName,
				Image: "envoy:test",
			})

			err := k8sClient.Create(ctx, pod)
			Expect(err).NotTo(HaveOccurred())

			// Count envoy-proxy containers — should be exactly 1 (the pre-existing one)
			count := 0
			for _, c := range pod.Spec.Containers {
				if c.Name == injector.EnvoyProxyContainerName {
					count++
				}
			}
			Expect(count).To(Equal(1))
		})
	})
})

func containerNames(containers []corev1.Container) []string {
	names := make([]string, len(containers))
	for i, c := range containers {
		names[i] = c.Name
	}
	return names
}

func initContainerNames(containers []corev1.Container) []string {
	return containerNames(containers)
}
