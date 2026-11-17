#!/usr/bin/env python3
"""Pairs CHANGE and PRESENTED lines printed by the stack spikes.

CHANGE <t>                      the model changed at t (seconds, CACurrentMediaTime)
PRESENTED <submitted> <shown>   a frame was submitted, and reached the display at `shown` (0 = never)
"""
import statistics
import sys


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    rank = q * (len(values) - 1)
    low, high = int(rank), min(int(rank) + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (rank - low)


def main(path, period=1 / 120):
    changes, frames, target_errors = [], [], []
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) == 2 and parts[0] == "CHANGE":
            changes.append(float(parts[1]))
        elif len(parts) in (3, 4) and parts[0] == "PRESENTED":
            frames.append((float(parts[1]), float(parts[2])))
            if len(parts) == 4 and float(parts[2]) > 0 and float(parts[3]) > 0:
                target_errors.append((float(parts[2]) - float(parts[3])) / period)
    frames.sort()
    shown = [f for f in frames if f[1] > 0]
    dropped = len(frames) - len(shown)
    print(f"frames {len(frames)} (never shown {dropped}), changes {len(changes)}")
    to_display, to_submit, submit_to_display = [], [], []
    unreported = 0
    for change in changes:
        frame = next((f for f in frames if f[0] >= change), None)
        if frame is None:
            continue
        if frame[1] <= 0:
            unreported += 1  # the frame that carried this change reported no display time
            continue
        to_display.append((frame[1] - change) * 1000)
        to_submit.append((frame[0] - change) * 1000)
        submit_to_display.append((frame[1] - frame[0]) * 1000)
    if unreported:
        print(f"  changes whose frame reported no display time: {unreported}")
    for name, values in (("change -> displayed", to_display), ("change -> submitted", to_submit),
                         ("submitted -> displayed", submit_to_display)):
        if values:
            print(f"  {name:24} p50 {pct(values, .5):6.2f}  p95 {pct(values, .95):6.2f}  max {max(values):6.2f}  "
                  f"mean {statistics.mean(values):6.2f} ms  (n={len(values)})")
    leads = sorted((f[1] - f[0]) * 1000 for f in shown[5:])
    if leads:
        print(f"  submitted -> displayed over all frames: min {leads[0]:.2f}  p05 {pct(leads, .05):.2f}  p50 {pct(leads, .5):.2f}  max {leads[-1]:.2f} ms")
    times = sorted(f[1] for f in shown)
    gaps = [(b - a) / period for a, b in zip(times, times[1:])]
    if gaps and not changes:
        steady = gaps[30:]
        missed = sum(round(g) - 1 for g in steady if g > 1.5)
        print(f"  motion: {len(steady)} intervals, refreshes without a frame {missed}, "
              f"p50 {pct(steady, .5):.2f} p95 {pct(steady, .95):.2f} max {max(steady):.2f} periods")
        lead = [(f[1] - f[0]) * 1000 for f in shown[30:]]
        print(f"  submitted -> displayed p50 {pct(lead, .5):.2f} p95 {pct(lead, .95):.2f} max {max(lead):.2f} ms")


if __name__ == "__main__":
    main(sys.argv[1])
