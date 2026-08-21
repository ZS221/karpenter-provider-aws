#!/usr/bin/env bash
# Extended Kubelet Configuration + CEL expressions -- live demo driver.
#
#   ./demo.sh            run all four beats, pausing between each
#   ./demo.sh 2          run only beat 2
#   ./demo.sh 1 3        run beats 1 and 3
#
# Every beat is idempotent and re-runnable. Beat 2 waits for real nodes and is the
# only slow one (~2-4 min). Beats 3 and 4 launch nothing and return in seconds.
#
# Env:
#   NO_PAUSE=1   don't wait for Enter between steps (for capturing output)

set -uo pipefail
cd "$(dirname "$0")"

CLUSTER="${CLUSTER:-karpenter-cel-demo}"    # override: export CLUSTER=<your-cluster>
NS=kube-system

# --- presentation helpers -----------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; CYN=$'\e[36m'; R=$'\e[0m'
else
  B=''; DIM=''; GRN=''; RED=''; YEL=''; CYN=''; R=''
fi

banner() { printf '\n%s%s\n  %s\n%s%s\n' "$B$CYN" "════════════════════════════════════════════════════════════════" "$1" "════════════════════════════════════════════════════════════════" "$R"; }
step()   { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
note()   { printf '%s  %s%s\n' "$DIM" "$1" "$R"; }
run()    { printf '\n%s$ %s%s\n' "$YEL" "$*" "$R"; eval "$@"; }
pause()  { [[ -n "${NO_PAUSE:-}" ]] && return 0; printf '\n%s  [Enter to continue]%s' "$DIM" "$R"; read -r; }

# Presenter-facing prose: lines to say out loud, caveats not to overstate, and
# troubleshooting hints. OFF by default so none of it can reach the projector --
# everything else in this script is written for the audience to read.
#
#   SPEAKER_NOTES=1 ./demo.sh    rehearse with the notes visible
#   ./demo.sh                    present; notes suppressed
speaker() { [[ -n "${SPEAKER_NOTES:-}" ]]; }

# Wait until an EC2NodeClass settles into a terminal ValidationSucceeded state.
# Returns 0 if True, 1 if False, 2 on timeout.
wait_validation() {
  local nc=$1 timeout=${2:-90} elapsed=0 s
  while (( elapsed < timeout )); do
    s=$(kubectl get ec2nodeclass "$nc" \
          -o jsonpath='{.status.conditions[?(@.type=="ValidationSucceeded")].status}' 2>/dev/null)
    case "$s" in
      True)  return 0 ;;
      False) return 1 ;;
    esac
    sleep 3; (( elapsed += 3 ))
  done
  return 2
}

# Print the ValidationSucceeded reason + message for a NodeClass, wrapped.
#
# Uses python rather than awk because condition messages can contain NEWLINES: a CEL
# compile error embeds a caret diagram pointing at the bad token, e.g.
#
#     ... expecting {...}
#      | min(110,
#      | ........^
#
# awk is record-per-line, so each continuation line rendered as a bogus extra
# NodeClass block with an empty reason. Reading all of stdin and splitting on the
# first two tabs keeps a multi-line message intact.
show_validation() {
  local nc=$1
  kubectl get ec2nodeclass "$nc" -o jsonpath='{range .status.conditions[?(@.type=="ValidationSucceeded")]}{.status}{"\t"}{.reason}{"\t"}{.message}{end}' 2>/dev/null \
    | NC="$nc" GRN="$GRN" RED="$RED" BOLD="$B" RST="$R" python3 -c '
import os, sys, textwrap

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
parts = raw.split("\t", 2)
status = parts[0].strip()
reason = parts[1].strip() if len(parts) > 1 else ""
message = parts[2].strip() if len(parts) > 2 else ""

col = os.environ["GRN"] if status == "True" else os.environ["RED"]
rst, bold = os.environ["RST"], os.environ["BOLD"]

print("  %s%s%s" % (bold, os.environ["NC"], rst))
print("    ValidationSucceeded : %s%s%s" % (col, status, rst))
print("    reason              : %s%s%s" % (col, reason, rst))
if message:
    indent = " " * 26
    # Collapse the message to a single logical paragraph before wrapping: the caret
    # diagram loses nothing by being flowed, and keeping it as separate lines is what
    # produced the broken output.
    flowed = " ".join(message.split())
    wrapped = textwrap.wrap(flowed, width=66) or [""]
    print("    message             : %s" % wrapped[0])
    for line in wrapped[1:]:
        print("%s%s" % (indent, line))
'
}

# Wait until N nodes matching a label selector are Ready. Prints a live counter.
wait_nodes() {
  local sel=$1 want=$2 timeout=${3:-600} elapsed=0 ready
  while (( elapsed < timeout )); do
    ready=$(kubectl get nodes -l "$sel" \
              -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null \
            | grep -c 'True')
    printf '\r  %s/%s nodes ready (%ss elapsed) ' "${ready:-0}" "$want" "$elapsed"
    [[ "${ready:-0}" -ge "$want" ]] && { printf '\n'; return 0; }
    sleep 6; (( elapsed += 6 ))
  done
  printf '\n'; return 1
}

# ==============================================================================
beat1() {
banner "BEAT 1 of 4 -- Extended kubelet configuration"
note "spec.kubelet used to be a closed struct with ~11 hardcoded fields."
note "It is now an open map validated against the upstream k8s.io/kubelet type."

step "The configuration we are about to apply"
run "grep -A 30 '  kubelet:' 01-extended.yaml | grep -v '^\s*#'"
pause

step "Apply it"
run "kubectl apply -f 01-extended.yaml"

step "Karpenter validates the whole document against k8s.io/kubelet"
if wait_validation demo-1-extended 90; then
  show_validation demo-1-extended
  printf '\n%s  All 15 fields accepted -- including 8 that were previously inexpressible.%s\n' "$GRN" "$R"
else
  show_validation demo-1-extended
  printf '\n%s  Unexpected -- see message above.%s\n' "$RED" "$R"
fi
pause

step "Schedule a pod so a node actually launches"
note "The fields we care about are kubelet-internal, so nothing proves they took"
note "effect until a real kubelet is running with them."
run "kubectl apply -f 01-workload.yaml"

step "Waiting for the node to register"
wait_nodes 'karpenter.sh/nodepool=demo-1-extended' 1 600 \
  || note "Timed out. Check: kubectl get nodeclaims | grep demo-1"


# ---------------------------------------------------------------------------
step "THE PROOF -- ask the running kubelet what config it is using"
note "This is the answer to 'how do I show the new fields taking effect on the node?'"
note "/configz is the kubelet's own debug endpoint, reached through the API server"
note "proxy. It returns the EFFECTIVE running config -- not what we asked for, but"
note "what the kubelet is actually operating with."

NODE=$(kubectl get nodes -l 'karpenter.sh/nodepool=demo-1-extended' \
         -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Fetch /configz, retrying because a freshly-Ready node is not immediately
# reachable through the API server proxy: AL2023 runs with serverTLSBootstrap=true,
# so the kubelet's serving certificate has to be issued and approved first. Observed
# failing ~30s after Ready and succeeding shortly after.
fetch_configz() {
  local node=$1 out=$2 tries=${3:-20} i
  for (( i = 1; i <= tries; i++ )); do
    if kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" > "$out" 2>/dev/null \
       && [[ -s "$out" ]]; then
      return 0
    fi
    # Only animate on a terminal; a redirected run would otherwise accumulate a
    # long trail of spaces in the captured transcript.
    [[ -t 1 ]] && printf '\r  waiting for kubelet serving cert (%s/%s) ' "$i" "$tries"
    sleep 6
  done
  [[ -t 1 ]] && printf '\n'
  return 1
}

if [[ -z "$NODE" ]]; then
  note "No demo-1-extended node yet -- the wait above must have timed out."
else
  printf '\n%s$ kubectl get --raw "/api/v1/nodes/%s/proxy/configz"%s\n' "$YEL" "$NODE" "$R"
  CFG_JSON=$(mktemp); ASKED_JSON=$(mktemp)
  # What we asked Karpenter for, as Karpenter stored it.
  kubectl get ec2nodeclass demo-1-extended -o jsonpath='{.spec.kubelet}' > "$ASKED_JSON" 2>/dev/null
  if fetch_configz "$NODE" "$CFG_JSON"; then
    [[ -t 1 ]] && printf '\r%*s\r' 50 ''
    # ONE node, compared against its own manifest. The previous version diffed two
    # nodes (demo-1-extended vs beat 2's demo-2-small), which meant every difference
    # had two possible causes: the field we set, or the fact that the two nodes came
    # from different NodeClasses. "Did the kubelet apply what I asked for?" is a
    # single-node question, and answering it that way makes both tables meaningful.
    ASKED_JSON="$ASKED_JSON" CFG_JSON="$CFG_JSON" python3 - <<'PYEOF'
import json, os, re, sys

asked = json.load(open(os.environ["ASKED_JSON"]))
running = json.load(open(os.environ["CFG_JSON"]))["kubeletconfig"]

# Fields only the extended open-map config can express -- the claim of this change.
# Anything else in spec.kubelet is something the old closed struct already had.
EXTENDED = {"registryBurst", "registryPullQPS", "maxParallelImagePulls", "podPidsLimit",
            "containerLogMaxSize", "containerLogMaxFiles", "topologyManagerPolicy",
            "serializeImagePulls"}

DURATION = re.compile(r"(?:(\d+)h)?(?:(\d+)m)?(?:([\d.]+)s)?")

def norm(v):
    # The kubelet re-serialises some values, so a raw string compare gives false
    # mismatches. Durations are the main case: 1m30s and 90s are the same threshold.
    if isinstance(v, dict):
        return dict((k, norm(x)) for k, x in v.items())
    s = str(v)
    m = DURATION.fullmatch(s)
    if m and any(m.groups()):
        h, mi, se = (float(g) if g else 0.0 for g in m.groups())
        return "%.3fs" % (h * 3600 + mi * 60 + se)
    return s

def applied(want, got):
    """Did the kubelet apply what we asked for?

    Map-valued fields (evictionHard, evictionSoft, kubeReserved, ...) are MERGED with
    the AMI family's defaults rather than replacing them, so the running map is a
    superset. Asking for evictionHard.memory.available=10% on AL2023 yields
    memory.available plus the default nodefs.available and nodefs.inodesFree. A plain
    equality check calls that a mismatch, which is wrong: every key we asked for is
    present with the value we asked for. So compare subset-wise for maps.

    Returns (ok, annotation).
    """
    w, g = norm(want), norm(got)
    if isinstance(w, dict) and isinstance(g, dict):
        missing = [k for k in w if k not in g or g[k] != w[k]]
        if missing:
            return False, "missing/differs: " + ",".join(sorted(missing))
        extra = [k for k in g if k not in w]
        return True, ("+%d default%s" % (len(extra), "" if len(extra) == 1 else "s")) if extra else ""
    return (w == g), ""

def table(title, fields):
    if not fields:
        return
    print("    %s" % title)
    print("      %-28s %-18s %-18s %-5s %s"
          % ("FIELD", "ASKED FOR", "KUBELET RUNNING", "MATCH", "NOTE"))
    print("      " + "-" * 86)
    for f in sorted(fields):
        want, got = asked[f], running.get(f, "<ABSENT>")
        ok, note = applied(want, got)
        print("      %-28s %-18s %-18s %-5s %s" % (
            f, json.dumps(want)[:17], json.dumps(got)[:17], "yes" if ok else "NO", note))
    print()

table("NEW -- only expressible with the extended config:",
      [f for f in asked if f in EXTENDED])
table("PRE-EXISTING -- the closed struct had these, and they still work:",
      [f for f in asked if f not in EXTENDED])

bad = sorted(f for f in asked if not applied(asked[f], running.get(f, "<ABSENT>"))[0])
print("    %d of %d fields applied as asked." % (len(asked) - len(bad), len(asked)))
if bad:
    print("    NOT applied: %s" % ", ".join(bad))
else:
    print('    ("+N defaults" means the kubelet merged the AMI family\'s defaults in')
    print("     alongside the key we set -- the value we asked for is unchanged.)")
PYEOF
    cat <<EOF
  ${B}This is the proof.${R} ASKED FOR is spec.kubelet as stored on the EC2NodeClass.
  KUBELET RUNNING comes from the kubelet's own /configz endpoint. 

  Both tables matter, for different reasons:
    NEW           fields the closed struct could not express at all.
    PRE-EXISTING  proof the open map did not regress what already worked.
EOF
  else
    printf '\n%s  /configz never became reachable.%s\n' "$YEL" "$R"
    note "Needs RBAC on nodes/proxy (cluster-admin has it) and the kubelet's"
    note "enableDebuggingHandlers, which defaults to true. Fall back to reading the"
    note "config file off the node directly:"
    printf '\n%s$ kubectl debug node/%s -it --image=busybox -- cat /host/etc/kubernetes/kubelet/config.json%s\n' "$YEL" "$NODE" "$R"
    note "(That spawns a privileged debug pod, so it is the backup rather than the default.)"
  fi
  rm -f "$CFG_JSON" "$ASKED_JSON"
fi
pause

# ---------------------------------------------------------------------------
step "Secondary: the UserData Karpenter rendered"
note "Weaker evidence than /configz -- it proves KARPENTER emitted the fields, not"
note "that the kubelet accepted them. Useful for showing the passthrough mechanism."
# Karpenter tags launch templates with karpenter.k8s.aws/ec2nodeclass (see
# utils.GetTags), so filter on the NodeClass rather than the cluster -- it targets
# this demo's template specifically instead of whatever was created most recently.
LT=$(aws ec2 describe-launch-templates \
      --filters "Name=tag:karpenter.k8s.aws/ec2nodeclass,Values=demo-1-extended" \
      --query 'sort_by(LaunchTemplates,&CreateTime)[-1].LaunchTemplateName' \
      --output text 2>/dev/null)
if [[ -n "$LT" && "$LT" != "None" ]]; then
  run "aws ec2 describe-launch-template-versions \
        --launch-template-name '$LT' --versions '\$Latest' \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text \
        | base64 -d | grep -iE 'registryBurst|registryPullQPS|podPidsLimit|containerLogMax|maxParallelImagePulls|topologyManagerPolicy'"
else
  note "No launch template found -- it is created on first node launch."
fi
}

# ==============================================================================
beat2() {
banner "BEAT 2 of 4 -- CEL expressions resolved per instance type"
note "The headline: one manifest, one expression, different config per node."

step "The configuration -- note these are STRINGS, not numbers"
# -A 7 is exactly the kubelet block: maxPods plus the two reservation maps. The previous
# -A 6 predated systemReserved and spilled two lines of the next document ("---" and
# "apiVersion:") onto the screen; it would now cut off systemReserved.memory instead.
run "grep -A 7 '  kubelet:' 02-cel-scaling.yaml"
note "Variables: vcpus, memory_mib, default_enis, ips_per_eni, max_pods, instance_type"
note "Functions: min(), max()"
pause

step "Apply the NodeClass + two NodePools pinned to different instance sizes"
run "kubectl apply -f 02-cel-scaling.yaml"
wait_validation demo-2-cel 90
show_validation demo-2-cel
note "Validated by EVALUATING the expression against every instance type in cache,"
note "not merely by compiling it."
pause

step "Schedule one pod onto each NodePool"
run "kubectl apply -f 02-workload.yaml"

step "Waiting for both nodes to register (this is the slow part, ~2-4 min)"
wait_nodes 'karpenter.sh/nodepool in (demo-2-small,demo-2-large)' 2 600 \
  || note "Timed out. Check: kubectl get nodeclaims | grep demo-2"

step "THE PAYOFF -- same expression, different resolved values"
run "kubectl get nodes -l 'karpenter.sh/nodepool in (demo-2-small,demo-2-large)' \
      -o custom-columns='NODEPOOL:.metadata.labels.karpenter\\.sh/nodepool,INSTANCE:.metadata.labels.node\\.kubernetes\\.io/instance-type,VCPU:.status.capacity.cpu,MAXPODS:.status.allocatable.pods,ALLOC-CPU:.status.allocatable.cpu,ALLOC-MEM:.status.allocatable.memory'"

cat <<EOF

  ${B}Expected${R}
    maxPods = "vcpus * 8"
      m5.large   2 vCPU  ->  ${GRN}16${R} pods
      m5.xlarge  4 vCPU  ->  ${GRN}32${R} pods

    kubeReserved.cpu = "max(60, vcpus * 30)"
      m5.large           ->  ${GRN}60m${R}    (max(60, 60))
      m5.xlarge          ->  ${GRN}120m${R}   (max(60, 120))

    systemReserved.cpu = "max(20, vcpus * 10)"
      m5.large           ->  ${GRN}20m${R}    (max(20, 20))
      m5.xlarge          ->  ${GRN}40m${R}    (max(20, 40))

  ALLOC-CPU is capacity minus BOTH reservations, so the column above should read
  1920m on m5.large (2000 - 60 - 20) and 3840m on m5.xlarge (4000 - 120 - 40).
EOF
pause

# Prove the CEL-resolved reservations actually took effect, by reading the values off
# the running kubelet and checking the kubelet's own allocatable arithmetic closes:
#
#   allocatable = capacity - kubeReserved - systemReserved - hardEvictionThreshold
#
# This belongs to beat 2 rather than beat 1: the numbers being checked here
# (kubeReserved from "memory_mib / 100") are CEL-resolved values, which is this beat's
# subject. Beat 1's fields are kubelet-internal and never appear in this arithmetic.
step "Proof the resolved reservations reached the kubelet -- and the math closes"
for pool in demo-2-small demo-2-large; do
  n=$(kubectl get nodes -l "karpenter.sh/nodepool=$pool" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "$n" ]] && continue
  cz=$(kubectl get --raw "/api/v1/nodes/${n}/proxy/configz" 2>/dev/null)
  [[ -z "$cz" ]] && continue
  caps=$(kubectl get node "$n" -o jsonpath='{.status.capacity.memory}{" "}{.status.allocatable.memory}' 2>/dev/null)
  # Env assignments must sit on python3, not on printf -- a prefix before printf
  # exports into printf's environment and never reaches the interpreter.
  printf '%s' "$cz" | POOL="$pool" CAPS="$caps" python3 -c '
import json, os, sys
cfg = json.load(sys.stdin)["kubeletconfig"]
cap_s, alloc_s = os.environ["CAPS"].split()

def mib(v):
    v = str(v).strip()
    for suf, mul in (("Ki", 1/1024), ("Mi", 1), ("Gi", 1024)):
        if v.endswith(suf):
            return float(v[:-2]) * mul
    return float(v) / (1024 * 1024)   # bare value is bytes

cap, alloc = mib(cap_s), mib(alloc_s)
kr_raw = cfg.get("kubeReserved", {}).get("memory", "0")
kr = mib(kr_raw)
sr = mib(cfg.get("systemReserved", {}).get("memory", "0"))
ev_raw = cfg.get("evictionHard", {}).get("memory.available", "0")
# A percentage threshold is a fraction of capacity; an absolute one is a quantity.
ev = cap * float(ev_raw.rstrip("%")) / 100 if str(ev_raw).endswith("%") else mib(ev_raw)

sr_raw = cfg.get("systemReserved", {}).get("memory", "0")

print("  %s" % os.environ["POOL"])
print("      kubeReserved.memory   = %-7s <- resolved from \"memory_mib / 100\"" % kr_raw)
print("      systemReserved.memory = %-7s <- resolved from \"memory_mib / 200\"" % sr_raw)
# Negated so the column reads as a subtraction ledger the audience can verify by eye.
# `or 0.0` because -0.0 is a real float in Python and "%.1f" renders it as "-0.0": an
# absent reservation used to print as negative zero, which reliably draws a question.
print("      %-40s %10.1f" % ("capacity", cap))
print("      %-40s %10.1f" % ("- kubeReserved.memory", -kr or 0.0))
print("      %-40s %10.1f" % ("- systemReserved.memory", -sr or 0.0))
print("      %-40s %10.1f" % ("- evictionHard[memory.available] (%s)" % ev_raw, -ev or 0.0))
print("      %-40s %10.1f" % ("= computed allocatable", cap - kr - sr - ev))
print("      %-40s %10.1f" % ("  reported allocatable", alloc))
d = abs((cap - kr - sr - ev) - alloc)
print("      %-40s %10s" % ("  closes?", "yes" if d < 2 else "NO (off by %.1f)" % d))
print()
'
done

cat <<EOF
  ${B}Why this matters${R}
    kubeReserved.memory here is not a number anyone typed -- it is
    "memory_mib / 100" evaluated against each instance type, rounded up to a 16Mi
    boundary, and handed to the kubelet. The arithmetic closing proves the resolved
    value is what the kubelet is really reserving.
EOF
if speaker; then
cat <<EOF

  ${DIM}The argument to make: EKS's default kubeReserved is 11Mi * maxPods + 255, driven by
  pod count and blind to how much memory the instance actually has. "memory_mib / 100"
  is ~1% of real memory. On memory-heavy instances the default over-reserves badly.
  That is a concrete reason to want expressions, not just "it is configurable".${R}
EOF
fi
}

# ==============================================================================
beat3() {
banner "BEAT 3 of 4 -- Invalid configuration never reaches a node"
note "ValidationSucceeded is a REQUIRED condition, so False blocks node launch."
note "These four NodeClasses have no NodePools. Nothing launches. That is the point."

step "Apply four deliberately-broken NodeClasses"
run "kubectl apply -f 03-invalid.yaml"
pause

for nc in demo-3a-uncompilable demo-3b-eval-failure demo-3c-unknown-field demo-3d-semantics; do
  case $nc in
    demo-3a-uncompilable) hdr="3a. Expression does not compile          maxPods: \"min(110,\"" ;;
    demo-3b-eval-failure) hdr="3b. Compiles, but divides by zero        \"1048576 / (vcpus - vcpus)\"" ;;
    demo-3c-unknown-field) hdr="3c. Unknown field (typo)                 registryBurstt: 20" ;;
    demo-3d-semantics)     hdr="3d. Semantically invalid                 4 distinct rule violations" ;;
  esac
  step "$hdr"
  wait_validation "$nc" 90
  show_validation "$nc"
done

cat <<EOF

  ${B}Why each one matters${R}
    3a  a compile check alone catches this
    3b  a compile check does ${B}not${R} -- only per-instance-type evaluation finds it
    3c  the API server cannot catch this: spec.kubelet is an open map, so the
        typo is caught by strict-decoding against k8s.io/kubelet
    3d  all four violations decode cleanly against the Go types; they are only
        wrong semantically, which is what validateKubeletSemantics is for

  ${B}Confirm nothing launched:${R}
EOF
run "kubectl get nodeclaims -o name | grep demo-3 || echo '  (no NodeClaims for any demo-3 NodeClass -- correct)'"
}

# ==============================================================================
beat4() {
banner "BEAT 4 of 4 -- Silent-drop prevention across AMI families"
note "Only AL2023 renders the raw kubelet config through to the node."
note "Other families apply only the subset Karpenter explicitly maps."
note "Without this check, extra fields are accepted, stored, then quietly discarded."

step "Apply three NodeClasses on non-AL2023 families"
run "kubectl apply -f 04-unsupported.yaml"
pause

step "4a. Bottlerocket -- unmanaged fields AND podsPerCore"
wait_validation demo-4a-bottlerocket 90
show_validation demo-4a-bottlerocket
note "podsPerCore IS mapped by Karpenter, but Bottlerocket has no setting to"
note "render it into (PodsPerCoreEnabled = false), so it is rejected too."
pause

step "4b. AL2 -- same unmanaged fields, but podsPerCore is supported here"
wait_validation demo-4b-al2 90
show_validation demo-4b-al2
note "Note podsPerCore is ABSENT from this message. The check is per-family,"
note "not a blanket denial."
pause

step "4c. Positive control -- AL2 restricted to fields it can actually apply"
if wait_validation demo-4c-al2-supported 90; then
  show_validation demo-4c-al2-supported
  printf '\n%s  Accepted -- including a CEL expression on kubeReserved, a managed field.%s\n' "$GRN" "$R"
  note "Extended config is not 'AL2023-only'. It is 'whatever your family can apply'."
else
  show_validation demo-4c-al2-supported
fi

cat <<EOF

  ${B}The point${R}
    The alternative to this check is a node that comes up without the
    configuration you asked for, with nothing anywhere telling you -- only
    discoverable by SSH-ing to the node and reading the kubelet config.
EOF
}

# ==============================================================================
# Fail fast if the cluster is unreachable. Without this, every wait_validation
# call burns its full 90s timeout and the demo dies of silence rather than of a
# visible error -- the worst way to find out your credentials lapsed.
if ! kubectl get --raw /readyz >/dev/null 2>&1; then
  printf '\n%s  Cannot reach the cluster.%s\n' "$RED$B" "$R"
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    printf '  AWS credentials have expired. Re-auth, then re-run:\n\n'
    printf '    %saws login%s   (or: ada credentials update --once --profile default)\n\n' "$B" "$R"
  else
    printf '  Credentials are valid but the API server is not responding.\n'
    printf '  Check: %skubectl config current-context%s\n\n' "$B" "$R"
  fi
  exit 1
fi

banner "Extended Kubelet Configuration + CEL -- $CLUSTER"
printf '  %-14s %s\n' "context:" "$(kubectl config current-context)"
printf '  %-14s %s\n' "gate:" "$(kubectl get deploy -n $NS karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}' 2>/dev/null)"
printf '  %-14s %s\n' "image:" "$(kubectl get deploy -n $NS karpenter -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*\///')"

if [[ $# -eq 0 ]]; then set -- 1 2 3 4; fi
for b in "$@"; do
  case $b in
    1) beat1 ;;
    2) beat2 ;;
    3) beat3 ;;
    4) beat4 ;;
    *) printf '%sunknown beat: %s%s\n' "$RED" "$b" "$R" ;;
  esac
  pause
done

banner "Done"
note "Tear down with: ./cleanup.sh demo"
