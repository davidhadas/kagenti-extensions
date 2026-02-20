package injector

import (
	"github.com/kagenti/kagenti-extensions/kagenti-webhook/internal/webhook/config"
)

// PrecedenceEvaluator determines which sidecars should be injected for a workload
// by evaluating a multi-layer precedence chain. Each layer can short-circuit with "no".
//
// Precedence order (highest to lowest):
//  1. Global feature gate (kill switch)
//  2. Per-sidecar feature gate
//  3. Namespace label (kagenti-enabled=true)
//  4. Workload label (kagenti.io/<sidecar>-inject=false)
//  5. TokenExchange CR override (stub — not yet implemented)
//  6. Platform defaults (sidecars.<sidecar>.enabled)
//
// spiffe-helper additionally evaluates a 7th layer after the standard chain:
//  7. SPIRE opt-out label (kagenti.io/spire=disabled blocks injection)
type PrecedenceEvaluator struct {
	featureGates   *config.FeatureGates
	platformConfig *config.PlatformConfig
}

// NewPrecedenceEvaluator creates a new evaluator with the given feature gates and platform config.
func NewPrecedenceEvaluator(fg *config.FeatureGates, pc *config.PlatformConfig) *PrecedenceEvaluator {
	if fg == nil {
		fg = config.DefaultFeatureGates()
	}
	if pc == nil {
		pc = config.CompiledDefaults()
	}
	return &PrecedenceEvaluator{
		featureGates:   fg,
		platformConfig: pc,
	}
}

// Evaluate determines which sidecars should be injected for a given workload.
//
// Parameters:
//   - namespaceLabels: labels from the namespace object
//   - workloadLabels: labels from the pod template or workload metadata
//   - tokenExchangeOverrides: per-sidecar overrides from TokenExchange CR (nil to skip)
func (e *PrecedenceEvaluator) Evaluate(
	namespaceLabels map[string]string,
	workloadLabels map[string]string,
	tokenExchangeOverrides *TokenExchangeOverrides,
) InjectionDecision {
	namespaceOptedIn := namespaceLabels[LabelNamespaceInject] == "true"

	// Resolve per-sidecar TokenExchange overrides
	var teEnvoy, teSpiffe, teClientReg *bool
	if tokenExchangeOverrides != nil {
		teEnvoy = tokenExchangeOverrides.EnvoyProxy
		teSpiffe = tokenExchangeOverrides.SpiffeHelper
		teClientReg = tokenExchangeOverrides.ClientRegistration
	}

	decision := InjectionDecision{
		EnvoyProxy: e.evaluateSidecar(
			"envoy-proxy",
			e.featureGates.EnvoyProxy,
			namespaceOptedIn,
			workloadLabels[LabelEnvoyProxyInject],
			teEnvoy,
			e.platformConfig.Sidecars.EnvoyProxy.Enabled,
		),
		SpiffeHelper: e.evaluateSpiffeHelper(
			e.featureGates.SpiffeHelper,
			namespaceOptedIn,
			workloadLabels,
			teSpiffe,
			e.platformConfig.Sidecars.SpiffeHelper.Enabled,
		),
		ClientRegistration: e.evaluateSidecar(
			"client-registration",
			e.featureGates.ClientRegistration,
			namespaceOptedIn,
			workloadLabels[LabelClientRegistrationInject],
			teClientReg,
			e.platformConfig.Sidecars.ClientRegistration.Enabled,
		),
	}

	// proxy-init always follows envoy-proxy
	decision.ProxyInit = SidecarDecision{
		Inject: decision.EnvoyProxy.Inject,
		Reason: "follows envoy-proxy decision",
		Layer:  decision.EnvoyProxy.Layer,
	}

	return decision
}

// evaluateSidecar evaluates the precedence chain for a single sidecar.
func (e *PrecedenceEvaluator) evaluateSidecar(
	sidecarName string,
	featureGateEnabled bool,
	namespaceOptedIn bool,
	workloadLabelValue string, // "", "true", or "false"
	crdEnabled *bool, // nil = not specified
	platformDefaultEnabled bool,
) SidecarDecision {
	// Layer 1: Global kill switch
	if !e.featureGates.GlobalEnabled {
		return SidecarDecision{
			Inject: false,
			Reason: "global kill switch disabled",
			Layer:  "global-gate",
		}
	}

	// Layer 2: Per-sidecar feature gate
	if !featureGateEnabled {
		return SidecarDecision{
			Inject: false,
			Reason: sidecarName + " feature gate disabled",
			Layer:  "feature-gate",
		}
	}

	// Layer 3: Namespace label
	if !namespaceOptedIn {
		return SidecarDecision{
			Inject: false,
			Reason: "namespace not opted in (missing " + LabelNamespaceInject + "=true)",
			Layer:  "namespace",
		}
	}

	// Layer 4: Workload label
	if workloadLabelValue == "false" {
		return SidecarDecision{
			Inject: false,
			Reason: "workload label disabled " + sidecarName,
			Layer:  "workload-label",
		}
	}

	// Layer 5: TokenExchange CR override
	// If specified, the CR is authoritative and overrides platform defaults
	if crdEnabled != nil {
		if *crdEnabled {
			return SidecarDecision{
				Inject: true,
				Reason: "TokenExchange CR enabled " + sidecarName,
				Layer:  "tokenexchange-cr",
			}
		}
		return SidecarDecision{
			Inject: false,
			Reason: "TokenExchange CR disabled " + sidecarName,
			Layer:  "tokenexchange-cr",
		}
	}

	// Layer 6: Platform defaults
	if !platformDefaultEnabled {
		return SidecarDecision{
			Inject: false,
			Reason: "platform default disabled " + sidecarName,
			Layer:  "platform-default",
		}
	}

	// All gates passed
	return SidecarDecision{
		Inject: true,
		Reason: "all gates passed",
		Layer:  "default",
	}
}

// evaluateSpiffeHelper evaluates the precedence chain for spiffe-helper.
// spiffe-helper follows the same standard 6-layer chain as other sidecars.
// The former Layer 7 SPIRE label requirement (kagenti.io/spire=enabled) has
// been removed: with opt-in injection (kagenti.io/inject=enabled), the full
// sidecar stack including spiffe-helper is injected by default.  Use the
// per-sidecar opt-out label (kagenti.io/spiffe-helper-inject=false) or the
// feature gate to suppress spiffe-helper specifically.
func (e *PrecedenceEvaluator) evaluateSpiffeHelper(
	featureGateEnabled bool,
	namespaceOptedIn bool,
	workloadLabels map[string]string,
	crdEnabled *bool,
	platformDefaultEnabled bool,
) SidecarDecision {
	return e.evaluateSidecar(
		"spiffe-helper",
		featureGateEnabled,
		namespaceOptedIn,
		workloadLabels[LabelSpiffeHelperInject],
		crdEnabled,
		platformDefaultEnabled,
	)
}
