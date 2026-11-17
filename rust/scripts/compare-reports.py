#!/usr/bin/env python3
"""Side-by-side headline numbers from Swift-app and Rust-app benchmark reports.

usage: compare-reports.py --swift a.json b.json ... --rust c.json d.json ...
Each metric is printed per run, in run order, for each app.
"""
import json
import sys


def load(path):
    data = json.load(open(path))
    if "results" in data:  # Swift app
        return "swift", {r["scenario"]: r for r in data["results"]}
    return "rust", data["scenarios"]


def get(report, *keys):
    for key in keys:
        if not isinstance(report, dict) or key not in report:
            return None
        report = report[key]
    return report


METRICS = [
    ("key -> display p50 (ms)", lambda r: get(r, "keyToDisplayMs", "p50")),
    ("key -> display p95 (ms)", lambda r: get(r, "keyToDisplayMs", "p95")),
    ("key -> display max (ms)", lambda r: get(r, "keyToDisplayMs", "max")),
    ("scroll lag (ms)", lambda r: get(r, "scroll", "lagMs")),
    ("first motion (ms)", lambda r: get(r, "scroll", "firstMotionMs")),
    ("uneven frames", lambda r: get(r, "scroll", "unevenFrames")),
    ("frames analysed", lambda r: get(r, "scroll", "frames")),
    ("jerk p50 (px)", lambda r: get(r, "scroll", "jerkPixelsP50")),
    ("jerk p95 (px)", lambda r: get(r, "scroll", "jerkPixelsP95")),
    ("stalled frames", lambda r: get(r, "scroll", "stallFrames")),
    ("jump frames", lambda r: get(r, "scroll", "jumpFrames")),
    ("missed refreshes while moving", lambda r: get(r, "scroll", "missedRefreshesWhileMoving")),
    ("burst frames", lambda r: get(r, "scroll", "burstFrames")),
    ("largest step (px)", lambda r: get(r, "scroll", "largestStepPixels")),
    ("step gap spread", lambda r: get(r, "scroll", "stepGapSpread")),
    ("drawn / ideal lines", lambda r: None if get(r, "scroll", "drawnLines") is None else f"{get(r, 'scroll', 'drawnLines')}/{get(r, 'scroll', 'idealLines')}"),
    ("display path (Rust app)", lambda r: r.get("displayPath") if isinstance(r, dict) else None),
    ("commit -> display p50 (ms)", lambda r: get(r, "commitToDisplayMs", "p50") or get(r, "keyStagesMedianMs", "display")),
    ("CPU (% of a core)", lambda r: r.get("cpuPercent", r.get("cpuPercentOfOneCore")) if isinstance(r, dict) else None),
    ("CPU without benchmark timers", lambda r: r.get("cpuPercentWithoutBenchmarkTimers") if isinstance(r, dict) else None),
    ("frames presented", lambda r: r.get("presentedFrames", r.get("framesDisplayed")) if isinstance(r, dict) else None),
]


def main(argv):
    groups = {"swift": [], "rust": []}
    current = None
    for arg in argv:
        if arg in ("--swift", "--rust"):
            current = arg[2:]
        else:
            groups[current].append(load(arg)[1])
    names = []
    for runs in groups.values():
        for run in runs:
            for name in run:
                if name not in names:
                    names.append(name)
    for name in names:
        print(f"## {name}")
        for label, metric in METRICS:
            cells = {}
            for app, runs in groups.items():
                values = [metric(run[name]) for run in runs if name in run]
                values = [v for v in values if v is not None]
                if values:
                    cells[app] = " / ".join(str(v) for v in values)
            if cells:
                print(f"  {label:32} swift: {cells.get('swift', '-'):34} rust: {cells.get('rust', '-')}")


if __name__ == "__main__":
    main(sys.argv[1:])
