#!/usr/bin/env bash
# Fix the three stale cel-* fixtures before redeploying HEAD.
#
# WHY THIS IS NEEDED
#   cel-al2, cel-bottlerocket and cel-windows each carry registryBurst and
#   serializeImagePulls -- unmanaged kubelet fields that only AL2023 passes
#   through to the node. They currently show Ready=True ONLY because the deployed
#   controller image (~Aug 11) predates commit 64651f57f (Aug 12), which added
#   validateKubeletFieldsSupported.
#
#   Redeploy HEAD and all three flip to ValidationSucceeded=False. That is the
#   feature working correctly, but it would look like a regression mid-demo.
#
#   Bottlerocket additionally fails on podsPerCore: Karpenter maps that field, but
#   Bottlerocket has no setting to render it into (PodsPerCoreEnabled = false).
#
# WHAT THIS DOES
#   A surgical JSON merge patch that removes ONLY the offending keys from
#   spec.kubelet. Nothing else in these NodeClasses is touched -- role, subnet and
#   security group selectors, AMI terms, and the remaining kubelet fields
#   (evictionHard, systemReserved with its CEL expression) all stay as they are.
#
#   Run this BEFORE `helm upgrade`, so the fixtures are already correct when the
#   new controller starts reconciling them.
#
#   The deliberate "this field would be silently dropped" demo lives in
#   04-unsupported.yaml instead, on its own demo-4* NodeClasses.

set -uo pipefail

B=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; R=$'\e[0m'

patch_nc() {
  local nc=$1 patch=$2
  printf '\n%s%s%s\n' "$B" "$nc" "$R"
  printf '%s  before: %s%s\n' "$DIM" "$(kubectl get ec2nodeclass "$nc" -o jsonpath='{.spec.kubelet}' 2>/dev/null)" "$R"
  kubectl patch ec2nodeclass "$nc" --type=merge -p "$patch" >/dev/null 2>&1 \
    && printf '%s  after : %s%s\n' "$GRN" "$(kubectl get ec2nodeclass "$nc" -o jsonpath='{.spec.kubelet}' 2>/dev/null)" "$R" \
    || printf '  (patch failed -- does %s exist?)\n' "$nc"
}

printf '%sRemoving unsupported kubelet fields from the stale cel-* fixtures.%s\n' "$B" "$R"

# AL2 passes through only the fields Karpenter maps. podsPerCore IS supported here.
patch_nc cel-al2 '{"spec":{"kubelet":{"registryBurst":null,"serializeImagePulls":null}}}'

# Bottlerocket: same, plus podsPerCore has no Bottlerocket setting to render into.
patch_nc cel-bottlerocket '{"spec":{"kubelet":{"registryBurst":null,"serializeImagePulls":null,"podsPerCore":null}}}'

# Windows passes through only mapped fields. podsPerCore IS supported here.
patch_nc cel-windows '{"spec":{"kubelet":{"registryBurst":null,"serializeImagePulls":null}}}'

cat <<EOF

${DIM}Left intentionally alone:
  cel-bad      maxPods: "min(110," -- your existing negative fixture, should stay False
  cel-test     all-expressions fixture on AL2023, unaffected
  cel-al2023   AL2023 passes everything through, unaffected
  cel-manual   AL2023, unaffected${R}

Next: helm upgrade to HEAD, then verify every cel-* NodeClass except cel-bad is Ready:

  kubectl get ec2nodeclasses
EOF
