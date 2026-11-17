#!/usr/bin/env python3
"""Memory and idle CPU of NeoLink (Rust) against VS Code on the same folder and file (macOS).

Each app is launched, left to settle, then measured over a quiet interval: the physical footprint of all
its processes (what Activity Monitor reports as Memory; `footprint`), resident memory, and CPU used.
VS Code runs with a fresh, throwaway profile and no extensions, so the user's own is never touched.

    python3 -I scripts/compare-editors.py <folder> <file> [--rounds 3] [--settle 15] [--neolink target/release/neolink]

Typing latency and scrolling are measured by the app's own benchmark (`NEOLINK_BENCHMARK`), not here.
"""
import argparse, json, os, shutil, subprocess, tempfile, time

VSCODE = "/Applications/Visual Studio Code.app/Contents/MacOS/Code"


def descendants(root):
    """Pids of root and all its descendants."""
    children = {}
    for line in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, todo = [], [root]
    while todo:
        pid = todo.pop()
        found.append(pid)
        todo.extend(children.get(pid, []))
    return found


def cpu_seconds(pid):
    text = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not text:
        return 0.0
    minutes, seconds = text.split(":") if ":" in text else ("0", text)
    return int(minutes) * 60 + float(seconds)


def resident_mib(pids):
    text = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return sum(int(value) for value in text.split()) / 1024


def footprint_mib(pids):
    total = 0
    for pid in pids:
        for line in subprocess.run(["footprint", "-f", "bytes", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines():
            if "Footprint:" in line:
                total += int(line.split("Footprint:")[1].split()[0])
                break
    return total / 1048576


def measure(name, command, settle, idle, marker=None, env=None):
    """`marker`: an app that relaunches itself detached is found by a string in its command lines."""
    launched = subprocess.Popen(command, env={**os.environ, **(env or {})}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def processes():
        if not marker:
            return descendants(launched.pid)
        roots = [int(pid) for pid in subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True).stdout.split()]
        return sorted({pid for root in roots for pid in descendants(root)})

    time.sleep(settle)
    pids = processes()
    before = {pid: cpu_seconds(pid) for pid in pids}
    time.sleep(idle)
    after = {pid: cpu_seconds(pid) for pid in pids}
    result = {
        "app": name,
        "processes": len(pids),
        "footprintMiB": round(footprint_mib(pids), 1),
        "residentMiB": round(resident_mib(pids), 1),
        "idleCpuPercent": round(sum(after[pid] - before[pid] for pid in pids) / idle * 100, 2),
    }
    for pid in reversed(processes()):
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    if marker:
        subprocess.run(["pkill", "-f", marker])
    time.sleep(2)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("file")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--settle", type=float, default=15.0)
    parser.add_argument("--idle", type=float, default=10.0)
    parser.add_argument("--neolink", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "target", "release", "neolink"))
    arguments = parser.parse_args()
    for _ in range(arguments.rounds):
        if os.path.exists(VSCODE):
            # VS Code's socket path must stay short (about 100 characters), so not under a long temp dir.
            profile = tempfile.mkdtemp(prefix="vsc", dir="/private/tmp")
            command = [VSCODE, "--user-data-dir", os.path.join(profile, "d"), "--extensions-dir", os.path.join(profile, "e"), "--disable-workspace-trust", "--skip-release-notes", "--skip-welcome", "--new-window", arguments.folder, arguments.file]
            print(json.dumps(measure("VS Code", command, arguments.settle, arguments.idle, marker=profile)), flush=True)
            shutil.rmtree(profile, ignore_errors=True)
        command = [arguments.neolink, arguments.folder, arguments.file]
        print(json.dumps(measure("NeoLink", command, arguments.settle, arguments.idle, env={"NEOLINK_SETTINGS": "0"})), flush=True)


if __name__ == "__main__":
    main()
