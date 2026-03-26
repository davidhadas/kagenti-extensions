package injector

import (
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/utils/ptr"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

var operatorClientRegLog = logf.Log.WithName("operator-clientreg")

// AnnotationClientRegistrationSecretName is set on the pod template by kagenti-operator when it manages
// Keycloak client registration. The value is the name of a Secret in the pod namespace containing
// keys client-id.txt and client-secret.txt. The webhook mounts them for every container that uses
// the shared-data volume (same paths as the client-registration sidecar: /shared/client-id.txt,
// /shared/client-secret.txt).
const AnnotationClientRegistrationSecretName = "kagenti.io/client-registration-secret-name"

const operatorClientRegVolumeName = "kagenti-operator-clientreg"

// NeedsOperatorClientRegVolumePatch reports whether the pod still needs Secret volume mounts for
// operator-managed client registration (e.g. after webhook reinvocation when sidecars were injected first).
func NeedsOperatorClientRegVolumePatch(podSpec *corev1.PodSpec, annotations map[string]string) bool {
	secretName := strings.TrimSpace(annotations[AnnotationClientRegistrationSecretName])
	if secretName == "" {
		return false
	}
	if !volumeExists(podSpec.Volumes, operatorClientRegVolumeName) {
		return true
	}
	for i := range podSpec.Containers {
		if !containerVolumeMountExists(podSpec.Containers[i].VolumeMounts, "shared-data") {
			continue
		}
		if !containerHasOperatorRegMount(podSpec.Containers[i], "/shared/client-secret.txt") ||
			!containerHasOperatorRegMount(podSpec.Containers[i], "/shared/client-id.txt") {
			return true
		}
	}
	return false
}

func containerHasOperatorRegMount(c corev1.Container, mountPath string) bool {
	for _, m := range c.VolumeMounts {
		if m.Name == operatorClientRegVolumeName && m.MountPath == mountPath {
			return true
		}
	}
	return false
}

// ApplyOperatorClientRegSecretVolumes mounts operator-provisioned client credentials into any
// container that already mounts shared-data (injected sidecars and any user container that shares it).
func ApplyOperatorClientRegSecretVolumes(podSpec *corev1.PodSpec, annotations map[string]string) {
	secretName := strings.TrimSpace(annotations[AnnotationClientRegistrationSecretName])
	if secretName == "" {
		return
	}

	operatorClientRegLog.Info("mounting kagenti-operator client credentials Secret for shared-data containers",
		"secretName", secretName,
		"volumeName", operatorClientRegVolumeName)

	if !volumeExists(podSpec.Volumes, operatorClientRegVolumeName) {
		podSpec.Volumes = append(podSpec.Volumes, corev1.Volume{
			Name: operatorClientRegVolumeName,
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{
					SecretName: secretName,
					Optional:   ptr.To(false),
				},
			},
		})
	}

	for i := range podSpec.Containers {
		if !containerVolumeMountExists(podSpec.Containers[i].VolumeMounts, "shared-data") {
			continue
		}
		appendSubPathMount(&podSpec.Containers[i], operatorClientRegVolumeName, "client-secret.txt", "/shared/client-secret.txt")
		appendSubPathMount(&podSpec.Containers[i], operatorClientRegVolumeName, "client-id.txt", "/shared/client-id.txt")
	}
}

func containerVolumeMountExists(mounts []corev1.VolumeMount, volumeName string) bool {
	for _, m := range mounts {
		if m.Name == volumeName {
			return true
		}
	}
	return false
}

func appendSubPathMount(c *corev1.Container, vol, subPath, mountPath string) {
	for _, m := range c.VolumeMounts {
		if m.Name == vol && m.MountPath == mountPath {
			return
		}
	}
	c.VolumeMounts = append(c.VolumeMounts, corev1.VolumeMount{
		Name:      vol,
		MountPath: mountPath,
		SubPath:   subPath,
		ReadOnly:  true,
	})
}
