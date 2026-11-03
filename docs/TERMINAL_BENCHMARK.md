# Terminal-output comparison

The [raw report](terminal-comparison-build24.json) contains all accepted samples, workload hashes, viewport grids and the NeoLink binary hash. Measurements compare NeoLink 1.11.0/build 24 with VS Code 1.144.0 on an M2 Max MacBook Pro. They are a limited terminal workload, not an overall IDE ranking.

## Method

Both apps ran full screen on the built-in display at a 120 Hz setting, using GPU rendering, 12-point text and 500 scrollback lines. NeoLink's grid was 227×63; VS Code's was 234×68. VS Code used a newly created profile without user extensions. Its original workspace stayed open to preserve unsaved edits, so whole-process memory and CPU were deliberately not compared. The test uses the same Python interpreter and precomputes the same ASCII bytes before starting the timer.

The producer handles partial writes and times `os.write` completion. This includes PTY backpressure and some terminal processing. It excludes startup, data generation, report writing and final pixel presentation. Kernel/application buffers can still contain pending output when the timer stops. It does not measure scrolling, keyboard latency, editor file opening, search or language services.

Three consecutive runs per app/workload used two seconds of rest between runs. The apps were tested sequentially, not randomized; desktop services were not controlled. Initial sustained samples overlapped a Swift build and were rejected; accepted sustained runs had no build running. Every accepted sample remains in the raw report, including the slower NeoLink burst sample.

## Reproduce

Create a disposable empty project and a fresh VS Code profile. Match GPU rendering, font size, scrollback and viewport as closely as possible. Keep each tested terminal frontmost and unlocked, and stop builds/other heavy workloads. Run manually in each app's terminal, changing the report path for every sample:

```sh
python3 /path/to/NeoLink/scripts/benchmark-terminal-output.py --lines 1000000 --report /tmp/app-run-1.json
```

Repeat with `--lines 200000` for the burst. Check `bytes` and `sha256` match across apps. Report all runs and viewport differences. For stronger conclusions, randomize more runs on an otherwise idle machine, instrument final presentation, and add independent startup, typing, editor, search and energy tests. Command-line/profile options are described in the [VS Code CLI documentation](https://code.visualstudio.com/docs/configure/command-line).
