/*
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

// Offline preflight for the demo manifests.
//
// Runs the real v1.ValidateKubeletConfig + the CEL compile check from the branch
// against every EC2NodeClass in the given YAML files, and prints what Karpenter
// would decide -- without a cluster, credentials, or a deploy.
//
// Run from the repo root:
//
//	go run ./demo/preflight demo/*.yaml
//
// This directory is excluded via .git/info/exclude, so it never reaches a commit.
// It deliberately has no go.mod: `make verify` discovers every nested go.mod and
// runs golangci-lint and `go mod tidy` inside it, so a nested module here would
// interfere with the repo's own checks. As a plain package it only has to compile
// and lint cleanly, which it does.
package main

import (
	"fmt"
	"os"
	"strings"

	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/yaml"

	"k8s.io/apimachinery/pkg/api/resource"

	v1 "github.com/aws/karpenter-provider-aws/pkg/apis/v1"
	kubeletcel "github.com/aws/karpenter-provider-aws/pkg/cel"
)

type nodeClass struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		AMIFamily string                  `json:"amiFamily"`
		Kubelet   v1.KubeletConfiguration `json:"kubelet"`
	} `json:"spec"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: preflight <manifest.yaml>...")
		os.Exit(2)
	}
	celEnv, err := kubeletcel.NewEnvironment()
	if err != nil {
		fmt.Fprintf(os.Stderr, "building CEL env: %v\n", err)
		os.Exit(1)
	}

	failures := 0
	for _, path := range os.Args[1:] {
		// nolint:gosec // paths come from argv of a local developer tool, not from a request
		f, err := os.Open(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			os.Exit(1)
		}
		fmt.Printf("\n=== %s ===\n", path)
		dec := yaml.NewYAMLOrJSONDecoder(f, 4096)
		for {
			var nc nodeClass
			if err := dec.Decode(&nc); err != nil {
				break
			}
			if nc.Kind != "EC2NodeClass" {
				continue
			}
			failures += report(celEnv, nc)
		}
		f.Close()
	}
	fmt.Printf("\n%d NodeClass(es) would be rejected.\n", failures)
}

// report prints what Karpenter would decide for one NodeClass, mirroring the order
// the validation controller checks things in, and returns 1 if it would be rejected.
//
// collapsing it would make the correspondence harder to follow
//
//nolint:gocyclo // the branching mirrors the controller's own sequence of checks;
func report(celEnv *kubeletcel.CELEnvironment, nc nodeClass) int {
	fmt.Printf("\n  %s  (amiFamily: %s)\n", nc.Metadata.Name, nc.Spec.AMIFamily)

	// 1. Structural + semantic validation.
	if errs := v1.ValidateKubeletConfig(nc.Spec.Kubelet); len(errs) > 0 {
		fmt.Printf("    REJECT  InvalidKubeletConfiguration\n")
		for _, e := range errs {
			fmt.Printf("            - %s\n", e)
		}
		return 1
	}

	// 2. CEL compile check on the expression-capable fields.
	parsed, err := v1.ParseKubeletConfig(nc.Spec.Kubelet)
	if err != nil {
		fmt.Printf("    REJECT  parse error: %v\n", err)
		return 1
	}
	if parsed.MaxPods != nil && parsed.MaxPods.Type == intstr.String {
		if err := celEnv.ValidateExpression(parsed.MaxPods.StrVal); err != nil {
			fmt.Printf("    REJECT  KubeletExpressionInvalid\n            spec.kubelet.maxPods: %v\n", err)
			return 1
		}
	}
	for field, m := range map[string]map[string]string{
		"kubeReserved":   parsed.KubeReserved,
		"systemReserved": parsed.SystemReserved,
	} {
		for k, val := range m {
			if _, qErr := resource.ParseQuantity(val); qErr == nil {
				continue
			}
			if err := celEnv.ValidateExpression(val); err != nil {
				fmt.Printf("    REJECT  KubeletExpressionInvalid\n            spec.kubelet.%s[%s]: %v\n", field, k, err)
				return 1
			}
		}
	}

	// 3. Report which fields Karpenter does not itself map. On families other than
	// AL2023 these are what the validation controller rejects as unsupported.
	unmanaged := v1.UnmanagedKubeletFields(nc.Spec.Kubelet)
	fmt.Printf("    ACCEPT  (structural + expression checks pass)\n")
	if len(unmanaged) > 0 {
		fmt.Printf("            unmanaged fields (AL2023-only): %s\n", strings.Join(unmanaged, ", "))
		if !strings.EqualFold(nc.Spec.AMIFamily, "AL2023") && !strings.EqualFold(nc.Spec.AMIFamily, "Custom") {
			fmt.Printf("            -> on %s this becomes UnsupportedKubeletConfiguration\n", nc.Spec.AMIFamily)
			return 1
		}
	}
	if parsed.PodsPerCore != nil && strings.EqualFold(nc.Spec.AMIFamily, "Bottlerocket") {
		fmt.Printf("            -> podsPerCore on Bottlerocket becomes UnsupportedKubeletConfiguration\n")
		return 1
	}
	return 0
}
