#!/usr/bin/env bash
# Build one controller image per arm and record the digests in arms.env.
#
# Each arm is built in its own detached git worktree under /tmp, so your checkout is
# never moved and never dirtied -- important, because the whole experiment hinges on
# V2 being exactly the commit you have checked out.
#
# All three are built with the SAME local Go toolchain, the same ko, and the same base
# image. That is the point of building V0/V1 from source instead of pulling
# public.ecr.aws/karpenter/controller:1.14.0: a released image was built by a different
# toolchain on different hardware, and toolchain differences are easily as large as the
# effect we are measuring.
#
#   ./build-arms.sh            build all three
#   ./build-arms.sh v2         build one
#   ./build-arms.sh --clean    remove leftover worktrees and exit

set -euo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"
REPO=$(cd "${HERE}/../../.." && pwd)
WT_ROOT=/tmp/karpenter-ab
ARMS_ENV="${HERE}/arms.env"

cleanup_worktrees() {
  cd "$REPO"
  for a in "${ARMS[@]}"; do
    [[ -d "${WT_ROOT}/${a}" ]] && git worktree remove --force "${WT_ROOT}/${a}" 2>/dev/null || true
  done
  git worktree prune
}

if [[ "${1:-}" == "--clean" ]]; then
  step "Removing A/B worktrees"; cleanup_worktrees; ok "done"; exit 0
fi

TARGETS=("${ARMS[@]}")
[[ -n "${1:-}" ]] && TARGETS=("$1")

step "Preflight"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || die "AWS credentials are not valid."
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker Desktop."
ensure_kubeconfig   # only used to read the node arch below, but keeps this script off ~/.kube/config too
cd "$REPO"
[[ -z "$(git status --porcelain)" ]] || { git status --short; die "Working tree is dirty. The V2 arm must correspond to a real commit."; }
git fetch origin --quiet
ok "clean tree, credentials valid, docker up"

step "ECR login"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" 2>&1 | tail -1

export KO_DOCKER_REPO="$ECR"
export KOCACHE=/tmp/ko-cache-ab
mkdir -p "$WT_ROOT"

# .ko.yaml sets defaultPlatforms to linux/arm64 AND linux/amd64. Building both doubles
# the build time for no benefit: the controller only ever runs on the cluster's managed
# nodegroup, not on the nodes Karpenter provisions. Detect that arch and build just it.
PLATFORM="${PLATFORM:-}"
if [[ -z "$PLATFORM" ]]; then
  NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)
  PLATFORM="linux/${NODE_ARCH:-amd64}"
  [[ -n "$NODE_ARCH" ]] || warn "could not read node arch from the cluster; defaulting to ${PLATFORM}"
fi
info "building for ${PLATFORM} only (override with PLATFORM=...)"

# Append rather than truncate so building a single arm doesn't drop the others.
touch "$ARMS_ENV"

for arm in "${TARGETS[@]}"; do
  REF=$(arm_ref "$arm")
  WT="${WT_ROOT}/${arm}"

  step "$(arm_label "$arm")  —  ref ${REF}"

  git worktree remove --force "$WT" 2>/dev/null || true
  git worktree add -q --detach "$WT" "$REF"
  cd "$WT"
  BASE_SHA=$(git rev-parse --short HEAD)

  if arm_needs_pick "$arm"; then
    # Neutralise the one upstream perf commit that is in V2 but not in origin/main.
    # Committed rather than --no-commit so the worktree is clean: ko stamps version info
    # from git and warns loudly about a dirty tree, and a dirty tree would also mean the
    # image does not correspond to any commit.
    git -c user.name=ab -c user.email=ab@local cherry-pick "$CONFOUNDER_PICK" >/dev/null 2>&1 \
      || die "cherry-pick of ${CONFOUNDER_PICK} onto ${REF} failed. Resolve by hand in ${WT}."
    info "cherry-picked ${CONFOUNDER_PICK} (offering cache keys) on top of ${BASE_SHA}"
  fi

  # ko embeds cmd/controller/kodata/ into the image, and in this repo those entries are
  # symlinks: kodata/HEAD -> ../../../.git/HEAD and kodata/refs -> ../../../.git/refs.
  # That works in a normal clone but NOT in a git worktree, where `.git` is a FILE holding
  # a gitdir pointer rather than a directory -- ko fails with
  # `EvalSymlinks(.../kodata/HEAD): not a directory`.
  #
  # Replace the symlinks with real copies from this worktree's actual git dir. HEAD is
  # per-worktree; refs lives in the COMMON dir (a worktree has no refs/ of its own). These
  # files only feed ko's version stamping, so copies are equivalent -- and doing it
  # identically for all three arms keeps the images comparable.
  GITDIR=$(git rev-parse --git-dir)
  COMMONDIR=$(git rev-parse --git-common-dir)
  rm -rf cmd/controller/kodata/HEAD cmd/controller/kodata/refs
  cp "${GITDIR}/HEAD" cmd/controller/kodata/HEAD
  cp -R "${COMMONDIR}/refs" cmd/controller/kodata/refs
  git -c user.name=ab -c user.email=ab@local add -A cmd/controller/kodata >/dev/null 2>&1 || true
  git -c user.name=ab -c user.email=ab@local commit -q -m "ab: dereference kodata symlinks for worktree build" >/dev/null 2>&1 || true
  info "kodata symlinks dereferenced for worktree build"

  TAG="ab-${arm}-${BASE_SHA}"
  info "building ${TAG} ..."
  IMG=$(ko build --bare --platform "$PLATFORM" --tags "$TAG" ./cmd/controller 2>/tmp/ko-${arm}.log) \
    || { tail -25 /tmp/ko-${arm}.log; die "ko build failed for ${arm}. Full log: /tmp/ko-${arm}.log"; }

  IMG_REPO=${IMG%@*}; IMG_REPO=${IMG_REPO%:*}
  IMG_DIGEST=${IMG#*@}
  ok "$IMG"

  # The CRDs and the chart are per-arm too, not just the image: V0's EC2NodeClass
  # schema has an int-only maxPods and V2's spec.kubelet is an open map. deploy-arm.sh
  # applies them straight out of the worktree, so the worktree has to survive the build.
  {
    echo "# $(arm_label "$arm")"
    echo "${arm}_REF=${REF}"
    echo "${arm}_SHA=${BASE_SHA}"
    echo "${arm}_TAG=${TAG}"
    echo "${arm}_IMG_REPO=${IMG_REPO}"
    echo "${arm}_IMG_DIGEST=${IMG_DIGEST}"
    echo "${arm}_WORKTREE=${WT}"
  } >> "$ARMS_ENV"

  cd "$REPO"
done

step "arms.env"
# De-duplicate, keeping the last definition of each key, so re-running one arm wins.
awk -F= '!/^#/ && NF>1 { seen[$1]=$0 } END { for (k in seen) print seen[k] }' "$ARMS_ENV" \
  | sort > "${ARMS_ENV}.tmp" && mv "${ARMS_ENV}.tmp" "$ARMS_ENV"
cat "$ARMS_ENV"

cat <<EOF

${GRN}Builds done.${R}
  Worktrees are intentionally left in place (${WT_ROOT}) -- deploy-arm.sh applies each
  arm's CRDs and chart from them. Run ./build-arms.sh --clean when the experiment is over.

  Next: ./deploy-arm.sh v1     (start with V1 to confirm the harness end-to-end)
EOF
