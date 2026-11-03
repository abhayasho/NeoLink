#!/usr/bin/env python3
"""Run NeoLink's interaction benchmark repeatedly and keep the raw results.

Each run builds the release binary (a failed build aborts the whole run), verifies the
executable is the one that was just built, then launches it with NEOLINK_BENCHMARK, samples
CPU and memory with `ps`, and watches screen lock, foreground app and window visibility with
bench-probe. A run is invalid if the build is stale, the screen locks, NeoLink loses the
foreground or its window, the workload does not finish, or a scrolling scenario's content did
not actually move a meaningful distance. Results go to .build/benchmarks/<label>-<time>/.

Scope caveats:
  - Scroll-offset sampling (ScrollPositionSampler) measures geometry changes per refresh. It
    does NOT prove correctly rendered pixels reached the display without shimmer or tearing.
  - Synthetic scroll events may not drive AppKit's real responsive-scrolling/momentum path.
    When they do not move the view, the run is marked invalid rather than reported as success.
    Visual smoothness is judged on a real trackpad, not from these numbers.

    python3 scripts/bench-run.py --label baseline --runs 5
    python3 scripts/bench-summary.py .build/benchmarks/baseline-*/
"""
import argparse, datetime, hashlib, json, os, platform, signal, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCENARIOS = ("idle,editor-open,editor-scroll,editor-flick,editor-reversal,editor-cursor,editor-type,"
                     "terminal-type,terminal-scroll,terminal-flood")


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as error:  # noqa: BLE001 - metadata is best effort
        return f"unavailable: {error}"


def build_release():
    """Builds the release binary and returns its path. Aborts the whole run on failure, so a
    benchmark never silently measures a stale build."""
    print("building release…", flush=True)
    result = subprocess.run(["swift", "build", "-c", "release"], cwd=ROOT)
    if result.returncode != 0:
        sys.exit(f"swift build failed (exit {result.returncode}); not running the benchmark")
    result = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"],
                            cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        sys.exit("could not resolve the successfully built release executable")
    binary = os.path.join(result.stdout.strip(), "NeoLink")
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        sys.exit(f"release executable not found at {binary}")
    return binary


def binary_digest(binary):
    digest = hashlib.sha256()
    with open(binary, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_digest():
    # Include vendor/shader and runtime Lua resources, not just app Swift files.
    digest = hashlib.sha256()
    paths = ["Package.swift", "Package.resolved", "Resources/Info.plist"]
    for base in ["Sources", "Resources/Editor", "Vendor/SwiftTerm"]:
        for directory, dirs, files in os.walk(os.path.join(ROOT, base)):
            dirs[:] = sorted(d for d in dirs if d not in {".build", ".git", "__pycache__"})
            paths.extend(os.path.relpath(os.path.join(directory, name), ROOT) for name in sorted(files))
    for path in sorted(paths):
        digest.update(path.encode() + b"\0")
        digest.update(bytes.fromhex(binary_digest(os.path.join(ROOT, path))))
    return digest.hexdigest()



def probe_binary():
    out = os.path.join(ROOT, ".build", "bench-tools", "bench-probe")
    source = os.path.join(ROOT, "scripts", "bench-probe.swift")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(source):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["swiftc", "-O", source, "-o", out], check=True)
    return out


def metadata(binary):
    digest = binary_digest(binary)
    displays = sh("system_profiler", "SPDisplaysDataType")
    return {
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
        "commit": sh("git", "-C", ROOT, "rev-parse", "HEAD"),
        "dirty": sh("git", "-C", ROOT, "status", "--porcelain") != "",
        "binary": binary, "binarySHA256": digest, "sourceSHA256": source_digest(),
        "binaryModified": datetime.datetime.fromtimestamp(os.path.getmtime(binary)).isoformat(timespec="seconds"),
        "macOS": platform.mac_ver()[0], "machine": sh("sysctl", "-n", "hw.model"),
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "display": [line.strip() for line in displays.splitlines() if any(k in line for k in ("Resolution", "Display Type", "Refresh"))],
        "power": sh("pmset", "-g", "ps").splitlines()[0] if sh("pmset", "-g", "ps") else "",
        "powerMode": [line.strip() for line in sh("pmset", "-g").splitlines() if "powermode" in line.lower() or "lowpower" in line.lower()],
        "thermal": sh("pmset", "-g", "therm"),
    }


def wait_until_quiet(quiet, limit):
    """Waits until the screen is unlocked and nobody has touched the keyboard, mouse or
    trackpad for `quiet` seconds, so a run neither disturbs someone working nor gets their
    input. Returns False after `limit` seconds."""
    deadline = time.time() + limit
    announced = False
    while time.time() < deadline:
        state = json.loads(subprocess.run([probe_binary(), "--idle"], capture_output=True, text=True).stdout)
        if not state["locked"] and state["idle"] >= quiet:
            return True
        if not announced:
            print(f"waiting: screen {'locked' if state['locked'] else 'in use'} (idle {state['idle']:.0f} s)", flush=True)
            announced = True
        time.sleep(5)
    return False


def run_once(binary, scenarios, source, directory, index, timeout, window):
    output = os.path.join(directory, f"run-{index}.json")
    probe_log = open(os.path.join(directory, f"run-{index}.probe.log"), "w")
    ps_log = open(os.path.join(directory, f"run-{index}.ps.log"), "w")
    env = dict(os.environ, NEOLINK_BENCHMARK=scenarios, NEOLINK_BENCHMARK_OUTPUT=output,
               NEOLINK_BENCHMARK_FILE=source, NEOLINK_WINDOW=window)
    app_log = open(os.path.join(directory, f"run-{index}.app.log"), "w")
    app = subprocess.Popen([binary], env=env, stdout=app_log, stderr=subprocess.STDOUT)
    probe = subprocess.Popen([probe_binary(), str(app.pid)], stdout=probe_log)
    started = time.time()
    while app.poll() is None and time.time() - started < timeout:
        ps_log.write(f"{time.time():.3f} {sh('ps', '-o', '%cpu=,rss=,time=', '-p', str(app.pid))}\n")
        ps_log.flush()
        time.sleep(0.5)
    timed_out = app.poll() is None
    if timed_out:
        app.send_signal(signal.SIGTERM)
        try: app.wait(5)
        except subprocess.TimeoutExpired: app.kill()
    probe.terminate(); probe.wait()
    for handle in (probe_log, ps_log, app_log): handle.close()
    return validate(directory, index, app.pid, timed_out, scenarios)


def validate(directory, index, pid, timed_out, scenarios):
    reasons = []
    if timed_out: reasons.append("timed out")
    with open(os.path.join(directory, f"run-{index}.probe.log")) as handle:
        samples = [json.loads(line) for line in handle if line.startswith("{")]
    if any(s["locked"] for s in samples): reasons.append("screen locked")
    # Idle time that drops means someone used the keyboard, mouse or trackpad during the run.
    if any(later.get("idle", 1e9) < earlier.get("idle", 0) - 0.01 for earlier, later in zip(samples, samples[1:])):
        reasons.append("user input during run")
    visible = [s for s in samples if s["onScreen"]]
    if not visible: reasons.append("window never on screen")
    else:
        first = visible[0]["t"]
        after = [s for s in samples if s["t"] > first + 1.0]
        if after and sum(1 for s in after if s["front"] == pid) < 0.95 * len(after): reasons.append("lost foreground")
        if after and sum(1 for s in after if s["onScreen"]) < 0.95 * len(after): reasons.append("window not visible")
    path = os.path.join(directory, f"run-{index}.json")
    if not os.path.exists(path): reasons.append("no result file")
    else:
        with open(path) as handle:
            results = json.load(handle).get("results", [])
        names = [r.get("scenario") for r in results]
        for scenario in scenarios.split(","):
            if scenario not in names: reasons.append(f"{scenario} missing")
        for r in results:
            if "error" in r: reasons.append(f"{r['scenario']}: {r['error']}")
            for problem in r.get("invalid", []): reasons.append(f"{r['scenario']}: {problem}")
            # A scroll scenario whose view did not actually move is not a valid measurement:
            # the synthetic input failed to drive real scrolling. Do not report it as success.
            if "scrollSamples" in r or r.get("scenario") == "ui-explorer-scroll":
                moved = r.get("scrollRefreshesMoved", 0)
                total = moved + r.get("scrollRefreshesRepeatedWhileMoving", 0)
                if moved < 20 or total < 20 or r.get("scrollTravelPoints", 0) < 100 or r.get("scrollRangePoints", 0) < 50:
                    reasons.append(f"{r['scenario']}: view did not scroll (synthetic input did not drive real scrolling; test on a trackpad)")
    return {"run": index, "valid": not reasons, "reasons": reasons, "pid": pid}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--scenarios", default=DEFAULT_SCENARIOS)
    parser.add_argument("--binary", help="explicit prebuilt baseline; skips rebuilding and is labeled prebuilt")
    parser.add_argument("--file", default=os.path.join(ROOT, "Sources", "FileBrowser", "LocalFileBrowserView.swift"))
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--window", default="900x560", help='content size in points, e.g. "1728x1084", or "max" for the whole screen')
    parser.add_argument("--quiet", type=float, default=20, help="seconds without user input before each run")
    parser.add_argument("--wait", type=float, default=1800, help="give up after waiting this long for a quiet, unlocked Mac")
    args = parser.parse_args()
    if args.runs < 1: parser.error("--runs must be positive")
    explicit_binary = args.binary is not None
    before_source = source_digest()
    args.binary = os.path.abspath(args.binary) if explicit_binary else build_release()
    if not os.path.isfile(args.binary) or not os.access(args.binary, os.X_OK): parser.error("--binary is not an executable file")
    if not explicit_binary and source_digest() != before_source:
        sys.exit("sources changed while building; rebuild before measuring")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    directory = os.path.join(ROOT, ".build", "benchmarks", f"{args.label}-{stamp}")
    os.makedirs(directory)
    meta = metadata(args.binary)
    if not explicit_binary and meta["sourceSHA256"] != before_source:
        sys.exit("sources changed after building; rebuild before measuring")
    meta.update({"buildMode": "prebuilt baseline" if explicit_binary else "successful release build", "label": args.label, "scenarios": args.scenarios, "file": args.file, "window": args.window, "runs": []})
    json.dump(meta, open(os.path.join(directory, "meta.json"), "w"), indent=2)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    for index in range(1, args.runs + 1):
        if not wait_until_quiet(args.quiet, args.wait):
            print(f"run {index}: not started; the Mac was locked or in use for {args.wait:.0f} s", flush=True)
            break
        if binary_digest(args.binary) != meta["binarySHA256"] or source_digest() != meta["sourceSHA256"]:
            print("not started: executable or source/resource inputs changed after build", flush=True)
            break
        verdict = run_once(args.binary, args.scenarios, args.file, directory, index, args.timeout, args.window)
        if binary_digest(args.binary) != meta["binarySHA256"] or source_digest() != meta["sourceSHA256"]:
            verdict["valid"] = False
            verdict["reasons"].append("executable or source/resource inputs changed during run")
        verdict["state"] = "first run after build" if index == 1 else "warm"
        meta["runs"].append(verdict)
        print(f"run {index}: {'valid' if verdict['valid'] else 'INVALID ' + '; '.join(verdict['reasons'])}", flush=True)
        json.dump(meta, open(os.path.join(directory, "meta.json"), "w"), indent=2)
        time.sleep(2)
    print(directory)


if __name__ == "__main__":
    sys.exit(main())
