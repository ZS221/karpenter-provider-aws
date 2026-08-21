#!/usr/bin/env bash
# Build and deploy branch HEAD to the CEL-test cluster.
#
# Deliberately uses `helm upgrade --reuse-values` rather than re-specifying the
# whole value set: your existing release already carries the right IRSA role,
# interruption queue, and feature gates, and guessing at those is how a working
# install gets clobbered the night before a demo. This changes only the image and
# (idempotently) re-asserts the NodeClassCEL gate.
#
# Prereqs: valid AWS credentials, ko, helm, kubectl, docker.
#
#   ./redeploy.sh            build, patch fixtures, deploy
#   ./redeploy.sh --dry-run  show what it would do, touch nothing

set -euo pipefail

REPO=$(cd "$(dirname "$(realpath "$0")")/.." && pwd)
CLUSTER="${CLUSTER:-karpenter-cel-demo}"    # override: export CLUSTER=<your-cluster>
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>
NS=kube-system
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/dev"

DRY=""
[[ "${1:-}" == "--dry-run" ]] && DRY=1

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; R=$'\e[0m'
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
die()  { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }

# ---------------------------------------------------------------- preflight
step "Credentials"
aws sts get-caller-identity --query Arn --output text 2>/dev/null \
  || die "AWS credentials are not valid. Re-auth (Isengard / ada credentials update) and re-run."

step "Context"
kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

step "Branch state"
cd "$REPO"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "extended_kubelet_config" ]] || printf '%s  on branch %s (expected extended_kubelet_config)%s\n' "$YEL" "$BRANCH" "$R"
[[ -z "$(git status --porcelain)" ]] || { git status --short; die "Working tree is dirty. Commit or stash so the image matches a commit."; }
COMMIT=$(git rev-parse --short HEAD)
printf '%s  %s @ %s%s\n' "$DIM" "$BRANCH" "$COMMIT" "$R"

step "Unit tests for the changed packages"
if [[ -n "$DRY" ]]; then
  printf '%s  (skipped in dry-run)%s\n' "$DIM" "$R"
else
  go test ./pkg/cel/... ./pkg/apis/v1/... ./pkg/controllers/nodeclass/... 2>&1 | tail -8
fi

step "Current release (for comparison afterwards)"
kubectl get deploy -n "$NS" karpenter \
  -o jsonpath='  image: {.spec.template.spec.containers[0].image}{"\n"}  gate : {.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}{"\n"}'

if [[ -n "$DRY" ]]; then
  step "Would now: ECR login -> ko build -> fix-fixtures.sh -> helm upgrade --reuse-values"
  printf '%s  Re-run without --dry-run to execute.%s\n' "$DIM" "$R"
  exit 0
fi

# ---------------------------------------------------------------- build
step "ECR login"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

step "ko build"
export KO_DOCKER_REPO="$ECR"
export KOCACHE=/tmp/ko-cache
IMG=$(ko build --bare --tags "cel-demo-${COMMIT}" github.com/aws/karpenter-provider-aws/cmd/controller)
printf '%s  %s%s\n' "$GRN" "$IMG" "$R"
IMG_REPO=${IMG%@*}; IMG_REPO=${IMG_REPO%:*}
IMG_DIGEST=${IMG#*@}

# ---------------------------------------------------------------- deploy
step "CRDs"
kubectl apply -f ./pkg/apis/crds/

step "Patch stale cel-* fixtures BEFORE the new controller reconciles them"
bash "$(dirname "$(realpath "$0")")/fix-fixtures.sh"

step "helm upgrade (reusing existing values)"
helm upgrade karpenter "${REPO}/charts/karpenter" \
  --namespace "$NS" \
  --reuse-values \
  --set "settings.awsFeatureGates.nodeClassCEL=true" \
  --set "controller.image.repository=${IMG_REPO}" \
  --set "controller.image.tag=cel-demo-${COMMIT}" \
  --set "controller.image.digest=${IMG_DIGEST}" \
  --wait --timeout 10m

step "Rollout"
kubectl rollout status -n "$NS" deploy/karpenter --timeout=5m

step "Verify"
kubectl get deploy -n "$NS" karpenter \
  -o jsonpath='  image: {.spec.template.spec.containers[0].image}{"\n"}  gate : {.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}{"\n"}'

step "NodeClass status after redeploy"
printf '%s  Expected: cel-bad False (your negative fixture). Everything else True.%s\n' "$DIM" "$R"
sleep 25
kubectl get ec2nodeclasses

cat <<EOF

${GRN}Ready.${R}
  Capture fallback output:  NO_PAUSE=1 ./demo.sh 2>&1 | tee capture/full-run.txt
  Run the demo:             ./demo.sh
EOF
