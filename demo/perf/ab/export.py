#!/usr/bin/env python3
"""Export one run's Prometheus series to local disk.

Called by export-window.sh, which owns the port-forward. Reads a run record written by
run-cell.sh and dumps, for each metric below, both a time series over each phase and a
scalar aggregate for the whole phase.

Why scalars as well as series: the arms are compared over ~10-25 minute windows, and an
instantaneous rate() line wobbles enough that eyeballing two of them side by side proves
nothing. A window integral -- total CPU-seconds burned, total bytes allocated, total GCs --
is one number per (arm, cell, phase) with very little variance, and it is what a claim like
"V2 costs 8% more CPU than V1 on identical inputs" has to be built on. The series are for
the graphs; the scalars are for the conclusion.

Only stdlib: this has to keep working on a laptop with no pip install.
"""
import json, os, sys, urllib.parse, urllib.request

PROM = os.environ.get("PROM", "http://localhost:19090")

# Karpenter runs 2 replicas with leader election and only the leader does work, so every
# per-pod query is wrapped in max() -- that selects the leader without having to know which
# pod it is, because the standby is essentially flat. Summing would halve the apparent
# per-replica cost and average would be worse.
# Queries use $POD / $JOB / $WINDOW placeholders and one substitution pass, deliberately
# NOT f-strings. PromQL is all braces, f-strings need every literal brace doubled, and the
# doubling is impossible to eyeball -- the first version of this file had a stray `}` in
# four queries that Python only caught as a SyntaxError.
POD = '{namespace="kube-system",pod=~"karpenter-.*",container="controller"}'
POD_SEL = POD[1:-1]      # for queries that add their own labels
JOB = '{job="karpenter"}'
JOB_SEL = JOB[1:-1]

# kind: "series"  -> query_range, kept as a time series (and summarised min/mean/max)
# kind: "scalar"  -> single instant query at window end, using $WINDOW as the range
#
# $WINDOW is substituted with the phase duration, so increase(...[$WINDOW]) is the exact
# total over the phase rather than an extrapolation from a fixed lookback.
NODECLASS = '{$JOB_SEL,controller=~"nodeclass.*"}'

METRICS = [
    # ---- controller resource use, from cAdvisor (works without the ServiceMonitor)
    ("cpu_cores",             "series", 'max(rate(container_cpu_usage_seconds_total$POD[1m]))'),
    ("cpu_seconds_total",     "scalar", 'max(increase(container_cpu_usage_seconds_total$POD[$WINDOW]))'),
    ("mem_working_set",       "series", 'max(container_memory_working_set_bytes$POD)'),
    ("mem_working_set_peak",  "scalar", 'max(max_over_time(container_memory_working_set_bytes$POD[$WINDOW]))'),
    # If this is not ~0 the CPU comparison is invalid: CFS throttling clamps both arms to
    # the limit and the difference disappears into the ceiling.
    ("cpu_throttled_seconds", "scalar", 'max(increase(container_cpu_cfs_throttled_seconds_total$POD[$WINDOW]))'),

    # ---- Go runtime, from Karpenter's own /metrics (needs the ServiceMonitor)
    ("go_heap_bytes",     "series", 'max(go_memstats_heap_alloc_bytes$JOB)'),
    ("go_heap_peak",      "scalar", 'max(max_over_time(go_memstats_heap_alloc_bytes$JOB[$WINDOW]))'),
    ("go_alloc_rate",     "series", 'max(rate(go_memstats_alloc_bytes_total$JOB[1m]))'),
    ("go_alloc_total",    "scalar", 'max(increase(go_memstats_alloc_bytes_total$JOB[$WINDOW]))'),
    ("goroutines",        "series", 'max(go_goroutines$JOB)'),
    ("gc_seconds_total",  "scalar", 'max(increase(go_gc_duration_seconds_sum$JOB[$WINDOW]))'),
    ("gc_count",          "scalar", 'max(increase(go_gc_duration_seconds_count$JOB[$WINDOW]))'),
    ("rss_bytes",         "series", 'max(process_resident_memory_bytes$JOB)'),
    ("cpu_seconds_process","scalar", 'max(increase(process_cpu_seconds_total$JOB[$WINDOW]))'),

    # ---- controller-runtime: where reconcile cost shows up
    ("reconcile_rate_nodeclass",    "series", 'sum(rate(controller_runtime_reconcile_total$NODECLASS[1m]))'),
    ("reconcile_total_nodeclass",   "scalar", 'sum(increase(controller_runtime_reconcile_total$NODECLASS[$WINDOW]))'),
    ("reconcile_p50_nodeclass",     "series", 'histogram_quantile(0.50, sum by (le) (rate(controller_runtime_reconcile_time_seconds_bucket$NODECLASS[2m])))'),
    ("reconcile_p99_nodeclass",     "series", 'histogram_quantile(0.99, sum by (le) (rate(controller_runtime_reconcile_time_seconds_bucket$NODECLASS[2m])))'),
    # Total seconds spent inside nodeclass Reconcile over the phase. Divided by
    # reconcile_total_nodeclass this gives mean reconcile cost -- the cleanest single
    # number for "how much did a reconcile get more expensive".
    ("reconcile_seconds_nodeclass", "scalar", 'sum(increase(controller_runtime_reconcile_time_seconds_sum$NODECLASS[$WINDOW]))'),
    ("workqueue_depth",             "series", 'sum(workqueue_depth$JOB)'),
    ("reconcile_errors",            "scalar", 'sum(increase(controller_runtime_reconcile_errors_total$JOB[$WINDOW]))'),

    # ---- Karpenter domain metrics: the provisioning path (Phase A)
    ("nodeclaims_created",    "scalar", 'sum(increase(karpenter_nodeclaims_created_total$JOB[$WINDOW]))'),
    ("nodeclaims_terminated", "scalar", 'sum(increase(karpenter_nodeclaims_terminated_total$JOB[$WINDOW]))'),
    ("cloudprovider_calls",   "scalar", 'sum(increase(karpenter_cloudprovider_duration_seconds_count$JOB[$WINDOW]))'),
    ("cloudprovider_seconds", "scalar", 'sum(increase(karpenter_cloudprovider_duration_seconds_sum$JOB[$WINDOW]))'),
    ("cloudprovider_errors",  "scalar", 'sum(increase(karpenter_cloudprovider_errors_total$JOB[$WINDOW]))'),
    ("nodes_ready",           "series", 'count(kube_node_status_condition{condition="Ready",status="true"})'),
]


def expand(expr, window):
    """One substitution pass. $NODECLASS must expand before $JOB_SEL, which it contains."""
    return (expr
            .replace("$NODECLASS", NODECLASS)
            .replace("$JOB_SEL", JOB_SEL)
            .replace("$POD_SEL", POD_SEL)
            .replace("$POD", POD)
            .replace("$JOB", JOB)
            .replace("$WINDOW", window))


def q(path, params):
    url = f"{PROM}/api/v1/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def series(expr, start, end, step=10):
    d = q("query_range", {"query": expr, "start": start, "end": end, "step": step})
    if d.get("status") != "success":
        return None, d.get("error", "query failed")
    res = d["data"]["result"]
    if not res:
        return [], None
    return [[float(t), (None if v in ("NaN", "+Inf", "-Inf") else float(v))] for t, v in res[0]["values"]], None


def scalar(expr, at):
    d = q("query", {"query": expr, "time": at})
    if d.get("status") != "success":
        return None, d.get("error", "query failed")
    res = d["data"]["result"]
    if not res:
        return None, None
    v = res[0]["value"][1]
    return (None if v in ("NaN", "+Inf", "-Inf") else float(v)), None


def summarise(pts):
    vals = [v for _, v in pts if v is not None]
    if not vals:
        return {"n": 0}
    return {"n": len(vals), "min": min(vals), "mean": sum(vals) / len(vals), "max": max(vals)}


def main():
    rec_path = sys.argv[1]
    rec = json.load(open(rec_path))
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    phases = {"phase_a": rec["phase_a"], "phase_b": rec["phase_b"]}
    out = {"run": rec, "prom": PROM, "phases": {}}
    empty, failed = [], []

    for pname, p in phases.items():
        start, end = int(p["start"]), int(p["end"])
        dur = max(end - start, 1)
        window = f"{dur}s"
        pdata = {"start": start, "end": end, "duration_s": dur, "series": {}, "scalars": {}, "summary": {}}
        print(f"\n  {pname}: {dur}s ({dur/60:.1f}m)")

        for name, kind, expr in METRICS:
            e = expand(expr, window)
            try:
                if kind == "series":
                    pts, err = series(e, start, end)
                    if err:
                        failed.append((pname, name, err)); print(f"    ! {name}: {err}"); continue
                    pdata["series"][name] = pts
                    pdata["summary"][name] = summarise(pts)
                    s = pdata["summary"][name]
                    if s["n"] == 0:
                        empty.append((pname, name)); print(f"    - {name}: NO DATA")
                    else:
                        print(f"    · {name}: mean={s['mean']:.4g} max={s['max']:.4g} (n={s['n']})")
                else:
                    v, err = scalar(e, end)
                    if err:
                        failed.append((pname, name, err)); print(f"    ! {name}: {err}"); continue
                    pdata["scalars"][name] = v
                    if v is None:
                        empty.append((pname, name)); print(f"    - {name}: NO DATA")
                    else:
                        print(f"    = {name}: {v:.6g}")
            except Exception as ex:  # noqa: BLE001 - one bad metric must not lose the run
                failed.append((pname, name, str(ex))); print(f"    ! {name}: {ex}")

        out["phases"][pname] = pdata

    dest = os.path.join(outdir, f"{rec['arm']}-{rec['cell']}.json")
    with open(dest, "w") as f:
        json.dump(out, f, indent=2)

    print(f"\n  wrote {dest}")
    if empty:
        print(f"\n  {len(empty)} metric(s) returned NO DATA -- likely a wrong name or a missing "
              f"ServiceMonitor. Fix before trusting a comparison:")
        for pn, n in sorted(set(empty)):
            print(f"    {pn}/{n}")
    if failed:
        print(f"\n  {len(failed)} metric(s) errored:")
        for pn, n, e in failed:
            print(f"    {pn}/{n}: {e}")

    # Throttling is a validity gate, not a metric: if the controller hit its CPU ceiling the
    # arms are clamped to the same value and the CPU comparison is meaningless.
    for pname, p in out["phases"].items():
        thr = p["scalars"].get("cpu_throttled_seconds")
        if thr and thr > 1.0:
            print(f"\n  WARNING {pname}: {thr:.1f}s of CFS throttling. The CPU comparison for this "
                  f"phase is NOT valid -- raise controller.resources.limits.cpu and re-run.")


if __name__ == "__main__":
    main()
