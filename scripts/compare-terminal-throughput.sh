#!/bin/bash
# Terminal output throughput, NeoLink against VS Code's integrated terminal (macOS).
#
# Runs the same producer (scripts/benchmark-terminal-output.py: N lines of 81 bytes written to the
# terminal) in each app, alternating, and prints how long the writes took. It measures how fast each
# terminal takes output in, not typing latency or when the last frame reached the screen.
#
# VS Code runs with a fresh, temporary profile and no extensions; a folder-open task starts the
# producer. Both terminals keep 10,000 lines of scrollback. Nothing is sent anywhere.
#
#   scripts/compare-terminal-throughput.sh [rounds] [lines]        (defaults: 3 rounds, 1000000 lines)
#
# NEOLINK_BIN names the NeoLink binary (default: target/release/neolink; build it first with
# `cargo build --release -p neolink`). VSCODE_BIN names VS Code's executable.
set -euo pipefail

rounds=${1:-3}
lines=${2:-1000000}
root=$(cd "$(dirname "$0")/.." && pwd)
neolink=${NEOLINK_BIN:-$root/target/release/neolink}
vscode=${VSCODE_BIN:-/Applications/Visual Studio Code.app/Contents/MacOS/Code}
producer=$root/scripts/benchmark-terminal-output.py
# Under /tmp: VS Code did not run the folder-open task from macOS's per-user temporary folder.
work=$(mktemp -d /tmp/neolink-throughput.XXXXXX)
trap 'rm -rf "$work"' EXIT

[ -x "$neolink" ] || { echo "No NeoLink binary at $neolink (cargo build --release -p neolink)" >&2; exit 1; }
[ -x "$vscode" ] || { echo "No VS Code at $vscode (set VSCODE_BIN)" >&2; exit 1; }

# Waits up to two minutes for a report file to appear.
wait_for() {
    for _ in $(seq 1 240); do
        [ -s "$1" ] && return 0
        sleep 0.5
    done
    echo "timed out waiting for $1" >&2
    return 1
}

for round in $(seq 1 "$rounds"); do
    echo "round $round of $rounds"

    # NeoLink: the command is typed into its first shell. Settings are neither read nor written.
    report=$work/neolink-$round.json
    NEOLINK_SETTINGS=0 NEOLINK_BENCHMARK=controls \
        NEOLINK_CONTROLS="type:python3 $producer --lines $lines --report $report^" \
        "$neolink" > /dev/null 2>&1 &
    pid=$!
    wait_for "$report" || true
    sleep 2
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    sleep 3

    # VS Code: a fresh profile; a task runs the same command when the folder opens.
    report=$work/vscode-$round.json
    profile=$work/vscode-profile-$round
    folder=$work/vscode-folder-$round
    mkdir -p "$profile/data/User" "$folder/.vscode"
    cat > "$profile/data/User/settings.json" << JSON
{"task.allowAutomaticTasks": "on", "security.workspace.trust.enabled": false, "workbench.startupEditor": "none",
 "terminal.integrated.scrollback": 10000, "workbench.panel.opensMaximized": "always", "update.mode": "none",
 "telemetry.telemetryLevel": "off", "extensions.autoCheckUpdates": false, "workbench.tips.enabled": false}
JSON
    cat > "$folder/.vscode/tasks.json" << JSON
{"version": "2.0.0", "tasks": [{"label": "throughput", "type": "shell",
 "command": "python3 '$producer' --lines $lines --report '$report'",
 "runOptions": {"runOn": "folderOpen"}, "presentation": {"reveal": "always", "panel": "new", "focus": true}}]}
JSON
    "$vscode" --user-data-dir "$profile/data" --extensions-dir "$profile/extensions" --new-window "$folder" > /dev/null 2>&1 &
    wait_for "$report" || true
    sleep 2
    pkill -f "user-data-dir $profile/data" || true
    sleep 3
done

python3 - "$work" << 'PY'
import glob, json, os, statistics, sys

work = sys.argv[1]
results = {}
for app in ("neolink", "vscode"):
    runs = [json.load(open(path)) for path in sorted(glob.glob(os.path.join(work, f"{app}-*.json")))]
    results[app] = runs
    if not runs:
        print(f"{app}: no completed runs")
        continue
    seconds = [run["seconds"] for run in runs]
    rates = [run["MiBPerSecond"] for run in runs]
    print(f"{app:8} {len(runs)} runs  {min(seconds):.2f}-{max(seconds):.2f} s  {min(rates):.1f}-{max(rates):.1f} MiB/s"
          f"  grid {runs[0]['columns']}x{runs[0]['rows']}  {runs[0]['bytes'] / 1048576:.1f} MiB")
if results["neolink"] and results["vscode"]:
    neolink = statistics.median(run["seconds"] for run in results["neolink"])
    vscode = statistics.median(run["seconds"] for run in results["vscode"])
    print(f"median: NeoLink {neolink:.2f} s, VS Code {vscode:.2f} s: {vscode / neolink:.1f}x faster ({(1 - neolink / vscode) * 100:.0f}% less time)")
PY
