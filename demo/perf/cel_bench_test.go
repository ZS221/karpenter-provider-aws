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

package perf

import (
	"context"
	"fmt"
	"testing"

	kubeletcel "github.com/aws/karpenter-provider-aws/pkg/cel"
)

// fleetSize approximates the number of instance types Karpenter resolves for an
// unconstrained NodePool in a commercial region. The exact number moves with EC2
// launches; what matters is the order of magnitude, because this is the multiplier
// on every per-instance-type cost in the change.
const fleetSize = 800

// fleet builds a spread of plausible instance shapes. Varying vcpus/memory across
// the fleet matters: a benchmark that evaluates the same expression against
// identical inputs every iteration would let the CPU's branch predictor and caches
// flatter the result in a way the real workload does not.
func fleet(n int) []kubeletcel.InstanceTypeVars {
	sizes := []struct {
		vcpus  int64
		memMiB int64
	}{
		{2, 8192}, {4, 16384}, {8, 32768}, {16, 65536},
		{32, 131072}, {48, 196608}, {64, 262144}, {96, 393216},
	}
	out := make([]kubeletcel.InstanceTypeVars, 0, n)
	for i := 0; i < n; i++ {
		s := sizes[i%len(sizes)]
		out = append(out, kubeletcel.InstanceTypeVars{
			VCPUs:        s.vcpus,
			MemoryMiB:    s.memMiB,
			DefaultENIs:  int64(3 + i%12),
			IPsPerENI:    int64(10 + i%20),
			MaxPods:      int64(29 + i%700),
			InstanceType: fmt.Sprintf("bench%d.xlarge", i),
		})
	}
	return out
}

// The six expressions from load.yaml's perf-cel NodeClass, so the in-process
// benchmark and the on-cluster load fixture measure the same shape of work.
var exprs = []string{
	"min(110, max(10, vcpus * 8))",
	"max(60, vcpus * 30)",
	"memory_mib / 100",
	"min(10, max(1, memory_mib / 16384))",
	"max(20, vcpus * 10)",
	"max(64, memory_mib / 200)",
}

func newEnv(tb testing.TB) *kubeletcel.CELEnvironment {
	tb.Helper()
	env, err := kubeletcel.NewEnvironment()
	if err != nil {
		tb.Fatalf("building CEL environment: %v", err)
	}
	return env
}

// BenchmarkEvaluateWarm is the steady-state per-evaluation cost: the compilation
// cache is already populated, so this is activation-map construction plus
// cel-go interpretation. This is the number to multiply by (instance types x
// expressions) when reasoning about a re-resolve.
func BenchmarkEvaluateWarm(b *testing.B) {
	env := newEnv(b)
	vars := fleet(1)[0]
	for _, expr := range exprs {
		if _, err := env.EvaluateExpression(expr, vars); err != nil { // warm the cache
			b.Fatalf("warmup %q: %v", expr, err)
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := env.EvaluateExpression(exprs[i%len(exprs)], vars); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkEvaluateCold pays compilation on every iteration by using a fresh
// environment, which empties the compiledCache. The gap between this and
// EvaluateWarm is exactly what the cache in compileCached buys -- worth knowing,
// because that cache has a TTL, so a NodeClass reconciled less often than the TTL
// pays the cold cost every time.
func BenchmarkEvaluateCold(b *testing.B) {
	vars := fleet(1)[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		env := newEnv(b) // excluded from the timing: env construction is once per process
		b.StartTimer()
		if _, err := env.EvaluateExpression(exprs[i%len(exprs)], vars); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkResolveFleet is the headline number: one full re-resolve of an
// unconstrained NodePool. Every cache-busting change to an EC2NodeClass's kubelet
// block costs this much CPU, and validation costs it again.
func BenchmarkResolveFleet(b *testing.B) {
	env := newEnv(b)
	f := fleet(fleetSize)
	for _, expr := range exprs { // warm, matching a steady-state controller
		if _, err := env.EvaluateExpression(expr, f[0]); err != nil {
			b.Fatalf("warmup %q: %v", expr, err)
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, vars := range f {
			for _, expr := range exprs {
				if _, err := env.EvaluateExpression(expr, vars); err != nil {
					b.Fatal(err)
				}
			}
		}
	}
	// Per-evaluation cost, so this stays comparable to EvaluateWarm even if
	// fleetSize or the expression list changes.
	b.ReportMetric(float64(fleetSize*len(exprs)), "evals/op")
}

// BenchmarkResolveResourceMap exercises the path the resolver actually calls,
// including the ParseQuantity short-circuit and the rounding in formatResourceResult
// -- not just the raw evaluator.
func BenchmarkResolveResourceMap(b *testing.B) {
	env := newEnv(b)
	f := fleet(fleetSize)
	m := map[string]string{
		"cpu":               "max(60, vcpus * 30)",
		"memory":            "memory_mib / 100",
		"ephemeral-storage": "min(10, max(1, memory_mib / 16384))",
	}
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for j := range f {
			vars := f[j]
			if _, err := env.ResolveResourceMap(ctx, m, func() (kubeletcel.InstanceTypeVars, error) {
				return vars, nil
			}); err != nil {
				b.Fatal(err)
			}
		}
	}
}

// BenchmarkResolveResourceMapStatic is the control: identical map shape, all values
// valid resource quantities, so ResolveResourceMap takes the ParseQuantity
// short-circuit and never touches CEL. Subtract this from ResolveResourceMap to get
// the true marginal cost of expressions over static values -- which is the question
// a reviewer will actually ask about this change.
func BenchmarkResolveResourceMapStatic(b *testing.B) {
	env := newEnv(b)
	f := fleet(fleetSize)
	m := map[string]string{
		"cpu":               "60m",
		"memory":            "80Mi",
		"ephemeral-storage": "1Gi",
	}
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for j := range f {
			vars := f[j]
			if _, err := env.ResolveResourceMap(ctx, m, func() (kubeletcel.InstanceTypeVars, error) {
				return vars, nil
			}); err != nil {
				b.Fatal(err)
			}
		}
	}
}

// BenchmarkNewEnvironment covers process startup. It runs once per controller
// process, so it is not a hot path -- but it registers every custom min/max
// overload, and a slow one shows up as leader-election latency after a restart.
func BenchmarkNewEnvironment(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := kubeletcel.NewEnvironment(); err != nil {
			b.Fatal(err)
		}
	}
}
