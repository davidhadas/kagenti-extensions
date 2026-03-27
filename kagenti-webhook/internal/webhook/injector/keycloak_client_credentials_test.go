package injector

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
)

func TestApplyKeycloakClientCredentialsSecretVolumes(t *testing.T) {
	secretName := "kagenti-keycloak-client-credentials-deadbeefcafe4242"
	volName := keycloakClientCredentialsVolumeName(secretName)

	spec := &corev1.PodSpec{
		Containers: []corev1.Container{
			{
				Name: "envoy-proxy",
				VolumeMounts: []corev1.VolumeMount{
					{Name: "shared-data", MountPath: "/shared"},
				},
			},
		},
	}
	ann := map[string]string{AnnotationKeycloakClientSecretName: secretName}
	ApplyKeycloakClientCredentialsSecretVolumes(spec, ann)

	if !volumeExists(spec.Volumes, volName) {
		t.Fatal("expected Keycloak client credentials volume")
	}
	c := spec.Containers[0]
	if !containerHasKeycloakCredentialsMount(c, volName, "/shared/client-secret.txt") ||
		!containerHasKeycloakCredentialsMount(c, volName, "/shared/client-id.txt") {
		t.Fatalf("mounts: %#v", c.VolumeMounts)
	}

	ApplyKeycloakClientCredentialsSecretVolumes(spec, ann) // idempotent
	if len(spec.Volumes) != 1 {
		t.Fatalf("volume count %d", len(spec.Volumes))
	}
}

func TestNeedsKeycloakClientCredentialsVolumePatch(t *testing.T) {
	secretName := "kagenti-keycloak-client-credentials-deadbeefcafe4242"

	spec := &corev1.PodSpec{
		Containers: []corev1.Container{
			{Name: "envoy-proxy", VolumeMounts: []corev1.VolumeMount{{Name: "shared-data", MountPath: "/shared"}}},
		},
	}
	ann := map[string]string{AnnotationKeycloakClientSecretName: secretName}
	if !NeedsKeycloakClientCredentialsVolumePatch(spec, ann) {
		t.Fatal("expected patch needed")
	}
	ApplyKeycloakClientCredentialsSecretVolumes(spec, ann)
	if NeedsKeycloakClientCredentialsVolumePatch(spec, ann) {
		t.Fatal("expected patch not needed")
	}
}
