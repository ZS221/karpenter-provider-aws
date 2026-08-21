#!/usr/bin/env bash
# Teardown helper.
#
#   ./cleanup.sh demo    delete everything this demo created (demo-* resources)
#   ./cleanup.sh stale   delete the leftover cel-* fixtures from earlier e2e runs
#   ./cleanup.sh all     both
#
# Both modes PRINT what they would delete and require you to type "yes".
# Deleting a NodePool/EC2NodeClass terminates its EC2 instances.

set -uo pipefail
cd "$(dirname "$0")"

MODE=${1:-}
B=$'\e[1m'; RED=$'\e[31m'; DIM=$'\e[2m'; R=$'\e[0m'

confirm() {
  printf '\n%s%s%s\n' "$RED$B" "$1" "$R"
  printf 'Type %syes%s to proceed: ' "$B" "$R"
  read -r ans
  [[ "$ans" == "yes" ]]
}

show() {
  local pat=$1
  printf '\n%sNodePools%s\n' "$B" "$R"
  kubectl get nodepools -o name 2>/dev/null | grep -E "$pat" | sed 's/^/  /' || echo "  (none)"
  printf '\n%sEC2NodeClasses%s\n' "$B" "$R"
  kubectl get ec2nodeclasses -o name 2>/dev/null | grep -E "$pat" | sed 's/^/  /' || echo "  (none)"
  printf '\n%sNodeClaims (these are running EC2 instances)%s\n' "$B" "$R"
  kubectl get nodeclaims -o wide 2>/dev/null | grep -E "$pat|^NAME" | sed 's/^/  /' || echo "  (none)"
}

purge() {
  local pat=$1
  kubectl get deployments -o name 2>/dev/null | grep -E "$pat" | xargs -r kubectl delete --wait=false
  kubectl get nodepools -o name 2>/dev/null      | grep -E "$pat" | xargs -r kubectl delete --wait=false
  kubectl get ec2nodeclasses -o name 2>/dev/null | grep -E "$pat" | xargs -r kubectl delete --wait=false
  printf '\n%sDeletion issued. Instances terminate as their NodeClaims drain.%s\n' "$DIM" "$R"
  printf '%sWatch with: kubectl get nodeclaims -w%s\n' "$DIM" "$R"
}

case "$MODE" in
  demo)
    show 'demo-'
    confirm "This deletes all demo-* resources and terminates their instances." && purge 'demo-'
    ;;
  stale)
    show 'cel-'
    confirm "This deletes all cel-* fixtures and terminates their instances." && purge 'cel-'
    ;;
  all)
    show 'demo-|cel-'
    confirm "This deletes ALL demo-* AND cel-* resources and their instances." && purge 'demo-|cel-'
    ;;
  *)
    printf 'usage: %s {demo|stale|all}\n' "$0"; exit 1
    ;;
esac
