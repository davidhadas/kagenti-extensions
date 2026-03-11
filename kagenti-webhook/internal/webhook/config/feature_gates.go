package config

// FeatureGates controls which sidecars are globally enabled/disabled.
// This is the highest-priority layer in the injection precedence chain.
type FeatureGates struct {
	GlobalEnabled      bool `json:"globalEnabled" yaml:"globalEnabled"`
	EnvoyProxy         bool `json:"envoyProxy" yaml:"envoyProxy"`
	SpiffeHelper       bool `json:"spiffeHelper" yaml:"spiffeHelper"`
	ClientRegistration bool `json:"clientRegistration" yaml:"clientRegistration"`
	// InjectTools controls whether tool workloads (kagenti.io/type=tool) receive
	// sidecar injection. Defaults to false — tools are not injected by default.
	InjectTools bool `json:"injectTools" yaml:"injectTools"`
	// PerWorkloadConfigResolution controls whether namespace ConfigMaps/Secrets
	// are read on every admission request (true) or cached per namespace and
	// reused across workloads (false). Defaults to false for performance — the
	// cache is cleared on webhook pod restart.
	PerWorkloadConfigResolution bool `json:"perWorkloadConfigResolution" yaml:"perWorkloadConfigResolution"`
}

// DefaultFeatureGates returns feature gates with sidecar injection enabled for
// agents and disabled for tools.
func DefaultFeatureGates() *FeatureGates {
	return &FeatureGates{
		GlobalEnabled:      true,
		EnvoyProxy:         true,
		SpiffeHelper:       true,
		ClientRegistration: true,
		InjectTools:        false,
	}
}

// DeepCopy creates a copy of the feature gates.
func (fg *FeatureGates) DeepCopy() *FeatureGates {
	if fg == nil {
		return nil
	}
	result := *fg
	return &result
}
