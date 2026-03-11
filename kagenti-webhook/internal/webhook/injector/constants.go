package injector

// Label constants used by the precedence evaluator.
// These are the per-sidecar workload opt-out labels.
const (
	// Per-sidecar workload labels — set value to "false" to disable injection
	LabelEnvoyProxyInject         = "kagenti.io/envoy-proxy-inject"
	LabelSpiffeHelperInject       = "kagenti.io/spiffe-helper-inject"
	LabelClientRegistrationInject = "kagenti.io/client-registration-inject"
)
