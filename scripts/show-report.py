#!/usr/bin/env python3
"""Prints the headline numbers of one or more benchmark reports (Rust app format)."""
import json
import sys

for path in sys.argv[1:]:
    data = json.load(open(path))
    env = data["environment"]
    print(f"# {path}: {env.get('window')} busy={env.get('busyMainThread')} smoothing={env.get('scrollSmoothing')}")
    for name, report in data["scenarios"].items():
        parts = []
        if "keyToDisplayMs" in report:
            k = report["keyToDisplayMs"]
            parts.append(f"key->display p50 {k['p50']} p95 {k['p95']} max {k['max']} (n={k['count']}, no echo {report['keysWithoutDisplayedEcho']})")
        if "switchToDisplayMs" in report:
            k = report["switchToDisplayMs"]
            parts.append(f"switch->display p50 {k['p50']} p95 {k['p95']} max {k['max']} (n={k['count']})")
        if "scroll" in report:
            s = report["scroll"]
            parts.append(f"lag {s['lagMs']} first {s['firstMotionMs']} uneven {s['unevenFrames']}/{s['frames']} jerk {s['jerkPixelsP50']}/{s['jerkPixelsP95']} "
                         f"stall {s['stallFrames']} jump {s['jumpFrames']} missed {s['missedRefreshesWhileMoving']} burst {s['burstFrames']} largest {s['largestStepPixels']} "
                         f"gapspread {s['stepGapSpread']} spread-events {s['eventsSpread']}/{s['inputEvents']} drawn {s['drawnLines']}/{s['idealLines']}")
        if "inputLatenessMs" in report:
            parts.append(f"input late p95 {report['inputLatenessMs']['p95']} max {report['inputLatenessMs']['max']}")
        c = report.get("commitToDisplayMs", {})
        parts.append(f"frames {report.get('framesDrawn')} commit->display p50 {c.get('p50')} cost p50 {report.get('drawCostMs', {}).get('p50')} late {report.get('framesLaterThanPlanned')} warm {report.get('framesRepeatedToKeepDisplayFast')} cpu {report.get('cpuPercentOfOneCore')}%")
        print(f"  {name:22} " + " | ".join(parts))
