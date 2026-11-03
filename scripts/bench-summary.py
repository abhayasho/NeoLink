#!/usr/bin/env python3
"""Summarize bench-run.py results: per scenario, the median (and range) across valid runs.

    python3 scripts/bench-summary.py .build/benchmarks/<dir> [<dir> ...] [--json out.json]

When raw samples are present (newer harness), pooled p50/p95/p99 across runs are reported too.
"""
import json, os, statistics, sys

KEYS = [
    ("keyToDisplayMs.p50", "key→display p50"), ("keyToDisplayMs.p95", "p95"), ("keyToDisplayMs.p99", "p99"),
    ("keyUnmatched", "unmatched keys"),
    ("contentIntervalMs.p50", "new-frame interval p50"), ("contentIntervalMs.p95", "p95"), ("contentIntervalMs.p99", "p99"),
    ("contentLatePercent", "late %"), ("missedRefreshes", "missed refreshes"), ("scroll.missedRefreshesWhileMoving", "missed while moving"), ("scroll.positionErrorLinesP95", "pos err p95 (lines)"), ("scroll.lagMs", "scroll lag ms"),
    ("scroll.stallFrames", "scroll stalls"), ("scroll.jumpFrames", "scroll jumps"),
    ("scroll.velocityErrorP95", "velocity err p95 (lines/s)"), ("scroll.settleMs", "settle ms"),
    ("scroll.settleReversal", "settle reversal"),
    ("mainThreadStallMs.max", "longest main stall"), ("mainThreadStallMs.over16ms", "stall samples >16ms"),
    ("clockCallbacks", "display callbacks"), ("presentedFrames", "drawables presented"), ("contentFrames", "content frames"),
    ("cpuPercent", "CPU %"), ("footprintMB", "memory MB"), ("seconds", "duration s"),
]


def flatten(value, prefix=""):
    out = {}
    if isinstance(value, dict):
        for key, item in value.items():
            out.update(flatten(item, f"{prefix}{key}."))
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        out[prefix[:-1]] = value
    return out


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))] if values else None


def load(directory):
    meta = json.load(open(os.path.join(directory, "meta.json")))
    runs = []
    for verdict in meta["runs"]:
        if not verdict["valid"]:
            continue
        path = os.path.join(directory, f"run-{verdict['run']}.json")
        runs.append(json.load(open(path)))
    return meta, runs


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    if out_json in args: args.remove(out_json)
    summary = {}
    for directory in args:
        meta, runs = load(directory)
        label = meta["label"]
        print(f"\n== {label}: {len(runs)}/{len(meta['runs'])} valid runs · {meta['commit'][:7]}{' (dirty)' if meta['dirty'] else ''} · {meta['date']}")
        for verdict in meta["runs"]:
            if not verdict["valid"]: print(f"   run {verdict['run']} invalid: {'; '.join(verdict['reasons'])}")
        scenarios = {}
        for run in runs:
            for result in run.get("results", []):
                scenarios.setdefault(result["scenario"], []).append(result)
        summary[label] = {}
        for name, results in scenarios.items():
            flat = [flatten(r) for r in results]
            row = {}
            for key, title in KEYS:
                values = [f[key] for f in flat if key in f]
                if values:
                    row[key] = {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)}
            pooled = {}
            for field in ("keyLatencySamplesMs", "contentIntervalSamplesMs", "stallSamplesMs"):
                samples = [s for r in results for s in r.get("raw", {}).get(field, [])]
                if samples:
                    pooled[field] = {"n": len(samples), "p50": percentile(samples, .5), "p95": percentile(samples, .95),
                                     "p99": percentile(samples, .99), "max": max(samples)}
            summary[label][name] = {"metrics": row, "pooled": pooled}
            parts = [f"{title} {row[key]['median']:g} [{row[key]['min']:g}–{row[key]['max']:g}]" for key, title in KEYS if key in row]
            print(f"  {name}: " + " · ".join(parts))
            for field, stats in pooled.items():
                print(f"      pooled {field}: n={stats['n']} p50={stats['p50']:g} p95={stats['p95']:g} p99={stats['p99']:g} max={stats['max']:g}")
    if out_json:
        json.dump(summary, open(out_json, "w"), indent=2)


if __name__ == "__main__":
    main()
