package injector

// SidecarDecision represents the injection decision for a single sidecar.
type SidecarDecision struct {
	Inject bool
	Reason string // human-readable reason for the decision
	Layer  string // which precedence layer made the decision
}

// InjectionDecision holds the per-sidecar injection decisions for a workload.
type InjectionDecision struct {
	EnvoyProxy         SidecarDecision
	ProxyInit          SidecarDecision // follows EnvoyProxy
	SpiffeHelper       SidecarDecision
	ClientRegistration SidecarDecision
}

// AnyInjected returns true if at least one sidecar will be injected.
func (d *InjectionDecision) AnyInjected() bool {
	return d.EnvoyProxy.Inject || d.SpiffeHelper.Inject || d.ClientRegistration.Inject
}
