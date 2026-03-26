package injector

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
)

func TestApplyOperatorClientRegSecretVolumes(t *testing.T) {
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
	ann := map[string]string{AnnotationClientRegistrationSecretName: "reg-secret"}
	ApplyOperatorClientRegSecretVolumes(spec, ann)

	if !volumeExists(spec.Volumes, operatorClientRegVolumeName) {
		t.Fatal("expected operator volume")
	}
	c := spec.Containers[0]
	if !containerHasOperatorRegMount(c, "/shared/client-secret.txt") ||
		!containerHasOperatorRegMount(c, "/shared/client-id.txt") {
		t.Fatalf("mounts: %#v", c.VolumeMounts)
	}

	ApplyOperatorClientRegSecretVolumes(spec, ann) // idempotent
	if len(spec.Volumes) != 1 {
		t.Fatalf("volume count %d", len(spec.Volumes))
	}
}

func TestNeedsOperatorClientRegVolumePatch(t *testing.T) {
	spec := &corev1.PodSpec{
		Containers: []corev1.Container{
			{Name: "envoy-proxy", VolumeMounts: []corev1.VolumeMount{{Name: "shared-data", MountPath: "/shared"}}},
		},
	}
	ann := map[string]string{AnnotationClientRegistrationSecretName: "s"}
	if !NeedsOperatorClientRegVolumePatch(spec, ann) {
		t.Fatal("expected patch needed")
	}
	ApplyOperatorClientRegSecretVolumes(spec, ann)
	if NeedsOperatorClientRegVolumePatch(spec, ann) {
		t.Fatal("expected patch not needed")
	}
}
