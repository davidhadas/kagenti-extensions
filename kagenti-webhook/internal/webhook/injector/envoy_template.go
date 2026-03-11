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
	"bytes"
	_ "embed"
	"text/template"
)

//go:embed envoy.yaml.tmpl
var envoyTemplateSrc string

var envoyTemplate = template.Must(template.New("envoy.yaml").Parse(envoyTemplateSrc))

// envoyTemplateData holds the values substituted into the envoy.yaml template.
type envoyTemplateData struct {
	AdminPort    int32
	OutboundPort int32
	InboundPort  int32
}

// RenderEnvoyConfig generates an envoy.yaml from the resolved config.
// If the resolved config already contains an EnvoyYAML string (from the
// namespace ConfigMap), it is returned as-is for backward compatibility.
func RenderEnvoyConfig(cfg *ResolvedConfig) (string, error) {
	if cfg.EnvoyYAML != "" {
		return cfg.EnvoyYAML, nil
	}

	data := envoyTemplateData{
		AdminPort:    cfg.Platform.Proxy.AdminPort,
		OutboundPort: cfg.Platform.Proxy.Port,
		InboundPort:  cfg.Platform.Proxy.InboundProxyPort,
	}

	var buf bytes.Buffer
	if err := envoyTemplate.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}
