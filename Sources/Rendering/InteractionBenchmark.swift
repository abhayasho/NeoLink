import AppKit
import QuartzCore
import SwiftTerm
import ImageIO

/// Developer benchmark, inactive unless `NEOLINK_BENCHMARK` is set (see docs/RENDERING.md).
/// Synthetic key and trackpad events are posted to this app's own event queue from a
/// background timer, so they pass through AppKit dispatch, monitors and the PTY like real
/// input, and keep arriving on schedule while the main thread is busy. Results come from
/// the window's frame scheduler: display-link cadence, and `presentedTime` of terminal frames.
@MainActor
final class InteractionBenchmark {
    private let window: WorkspaceWindow
    private let tabs: TabsController
    private let scenarios: [String]
    private let outputURL: URL
    private let sourceFile: URL
    private var results: [[String: Any]] = []
    private let eventQueue = DispatchQueue(label: "com.neolink.benchmark.events", qos: .userInteractive)

    static func startIfRequested(window: WorkspaceWindow, tabs: TabsController) {
        let environment = ProcessInfo.processInfo.environment
        guard let names = environment["NEOLINK_BENCHMARK"], !names.isEmpty else { return }
        if names.contains("capture") { TerminalView.allowsMetalFrameCapture = true }
        let output = URL(fileURLWithPath: environment["NEOLINK_BENCHMARK_OUTPUT"] ?? "/tmp/neolink-benchmark.json")
        let source = URL(fileURLWithPath: environment["NEOLINK_BENCHMARK_FILE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Documents/WorkspaceDocument.swift").path)
        let benchmark = InteractionBenchmark(window: window, tabs: tabs, scenarios: names.split(separator: ",").map(String.init),
                                             outputURL: output, sourceFile: source)
        Task { await benchmark.run() }
    }

    private init(window: WorkspaceWindow, tabs: TabsController, scenarios: [String], outputURL: URL, sourceFile: URL) {
        self.window = window; self.tabs = tabs; self.scenarios = scenarios
        self.outputURL = outputURL; self.sourceFile = sourceFile
    }

    private func run() async {
        await sleep(2.0)
        var editorFile: URL?
        for scenario in scenarios {
            switch scenario {
            case "terminal-type":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await measure(scenario) { await self.type(count: 75, interval: 1.0 / 25, into: view) }
                await postKeys(["\u{15}"], interval: 0.05) // Ctrl-U clears the typed line.
            case "terminal-scroll":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await postKeys(Array("clear; seq 1 6000\r").map(String.init), interval: 0.01)
                await sleep(1.5)
                // The viewport starts at the newest output: scroll back first, then forward.
                await measure(scenario) { await self.scroll(over: view, pointsPerEvent: -6, seconds: 2.5) }
            case "terminal-flood":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await postKeys(Array("clear; yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -n 3000000\r").map(String.init), interval: 0.01)
                await measure(scenario) { await self.sleep(3) }
                await postKeys(["\u{3}"], interval: 0.05) // Ctrl-C
                _ = view
            case "editor-open":
                let file = scratchCopy()
                editorFile = file
                await measure(scenario) {
                    self.tabs.openFile(file)
                    _ = await self.editorView(timeout: 10)
                    await self.sleep(1.5)
                }
            case "editor-scroll", "editor-type", "editor-cursor", "editor-capture":
                if editorFile == nil {
                    let file = scratchCopy(); editorFile = file
                    tabs.openFile(file)
                }
                guard let view = await editorView(timeout: 10) else { fail(scenario, "editor did not open"); continue }
                await sleep(1.0)
                if scenario == "editor-capture" {
                    await captureSmoothScroll(view)
                } else if scenario == "editor-scroll" {
                    await measure(scenario) { await self.scroll(over: view, pointsPerEvent: 6, seconds: 2.5) }
                } else if scenario == "editor-type" {
                    await measure(scenario) { await self.type(count: 75, interval: 1.0 / 25, into: view) }
                } else {
                    await postKeys(["\u{1B}", "g", "g", "i"], interval: 0.05) // Normal mode, top, insert.
                    await sleep(0.5)
                    await measure(scenario) { await self.postKeys(Array(repeating: Self.downArrow, count: 400), interval: 0.010) }
                }
            default:
                fail(scenario, "unknown scenario")
            }
            await sleep(0.8)
        }
        write()
        tabs.shutdownAgents(); tabs.codeSession.shutdown()
        if let editorFile { try? FileManager.default.removeItem(at: editorFile.deletingLastPathComponent()) }
        exit(0)
    }

    // MARK: Measurement

    private func measure(_ name: String, _ body: () async -> Void) async {
        let frames = window.frames
        frames.resetPresentationTiming()
        let started = CACurrentMediaTime()
        // Main-thread responsiveness: a background timer queues a block every 2 ms and
        // records how long each waited. A long wait is a stall of input and drawing.
        let probe = DispatchSource.makeTimerSource(flags: .strict, queue: eventQueue)
        let stalls = StallRecorder()
        probe.schedule(deadline: .now(), repeating: 0.002, leeway: .nanoseconds(0))
        probe.setEventHandler {
            let queued = CACurrentMediaTime()
            DispatchQueue.main.async { stalls.record(CACurrentMediaTime() - queued) }
        }
        probe.resume()
        await body()
        await sleep(0.35) // Let the last frames reach the display.
        probe.cancel()
        let elapsed = CACurrentMediaTime() - started
        let timing = frames.timing, presented = frames.presentation
        let p = PresentationTiming.percentile
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        let late = timing.intervals.filter { $0 > 1.5 / Double(frames.targetRate) }.count
        let contentLate = presented.contentIntervals.filter { $0 > 1.5 / Double(frames.targetRate) }.count
        var result: [String: Any] = [
            "scenario": name, "seconds": ms(elapsed) / 1000, "targetHz": frames.targetRate,
            "clockCallbacks": timing.intervals.count,
            "clockIntervalMs": ["p50": ms(p(timing.intervals, 0.5)), "p95": ms(p(timing.intervals, 0.95)),
                                "p99": ms(p(timing.intervals, 0.99)), "max": ms(timing.intervals.max() ?? 0)],
            "clockLatePercent": timing.intervals.isEmpty ? 0 : (Double(late) * 1000 / Double(timing.intervals.count)).rounded() / 10,
            "frameWorkMs": ["p95": ms(p(timing.work, 0.95)), "max": ms(timing.work.max() ?? 0)],
            "contentFrames": presented.contentIntervals.count,
            "contentIntervalMs": ["p50": ms(p(presented.contentIntervals, 0.5)), "p95": ms(p(presented.contentIntervals, 0.95)),
                                  "max": ms(presented.contentIntervals.max() ?? 0)],
            "contentLatePercent": presented.contentIntervals.isEmpty ? 0 : (Double(contentLate) * 1000 / Double(presented.contentIntervals.count)).rounded() / 10,
            "mainThreadStallMs": ["p99": ms(p(stalls.values, 0.99)), "max": ms(stalls.values.max() ?? 0),
                                  "over16ms": stalls.values.filter { $0 > 1.0 / 60 }.count],
        ]
        if !presented.inputLatencies.isEmpty {
            result["keyToDisplayMs"] = ["count": presented.inputLatencies.count, "p50": ms(p(presented.inputLatencies, 0.5)),
                                        "p95": ms(p(presented.inputLatencies, 0.95)), "max": ms(presented.inputLatencies.max() ?? 0)]
            result["keyStagesMedianMs"] = Dictionary(uniqueKeysWithValues: PresentationTiming.stageNames.map {
                ($0, ms(p(presented.stages[$0] ?? [], 0.5)))
            })
        }
        results.append(result)
        print("NeoLink benchmark", result)
    }

    private func fail(_ name: String, _ reason: String) { results.append(["scenario": name, "error": reason]) }

    // MARK: Smooth-scroll capture

    /// Scrolls the editor by part of a line and compares the frame drawn mid-scroll with the
    /// frame before it, shifted by the same distance. Writes the frames as PNG for inspection.
    private func captureSmoothScroll(_ view: InteractiveTerminalView) async {
        await postKeys(["\u{1B}", "g", "g", "1", "0", "j", "i"], interval: 0.05)
        await sleep(0.6)
        let scale = view.window?.backingScaleFactor ?? 2
        let cellPoints = CGFloat(view.cellSizeInPixels(source: view.getTerminal())?.height ?? 32) / scale
        guard let before = await capture(view) else { fail("editor-capture", "no frame"); return }
        var rows: [[String: Any]] = []
        for fraction in [0.25, 0.5, 0.75] {
            let points = (cellPoints * CGFloat(fraction) * scale).rounded() / scale
            wheel(view, deltaY: -points, phase: 1)
            await sleep(0.02)
            guard let mid = await capture(view) else { continue }
            await sleep(0.4) // Settles to the next whole line.
            guard let after = await capture(view) else { continue }
            let shift = Int((points * scale).rounded())
            let match = Self.compare(mid, before, shift: shift, height: Int(cellPoints * scale))
            let afterMatch = Self.compare(after, before, shift: Int((cellPoints * scale).rounded()), height: Int(cellPoints * scale))
            rows.append(["fraction": fraction, "shiftPx": shift, "midMatchesShiftedBefore": match, "afterMatchesOneLine": afterMatch])
            for (name, image) in [("before", before), ("mid-\(fraction)", mid), ("after-\(fraction)", after)] {
                Self.writePNG(image, to: outputURL.deletingPathExtension().appendingPathExtension("\(name).png"))
            }
            await postKeys(["\u{1B}", "g", "g", "1", "0", "j", "i"], interval: 0.05) // Back to the starting view.
            await sleep(0.6)
        }
        results.append(["scenario": "editor-capture", "comparisons": rows])
        print("NeoLink benchmark capture", rows)
    }

    private func wheel(_ view: InteractiveTerminalView, deltaY: CGFloat, phase: Int64) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(deltaY))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.frames.noteInteraction()
        view.deliverWheel(event)
    }

    private func capture(_ view: InteractiveTerminalView) async -> CGImage? {
        await withCheckedContinuation { (done: CheckedContinuation<CGImage?, Never>) in
            view.metalFrameCapture = { done.resume(returning: $0) }
            view.drawMetalFrameNow()
        }
    }

    /// Fraction of pixel rows of `image` that equal `reference` shifted up by `shift` rows,
    /// over the part of the frame both contain (the bottom line comes from new content).
    private static func compare(_ image: CGImage, _ reference: CGImage, shift: Int, height cell: Int) -> Double {
        guard let a = pixels(image), let b = pixels(reference), image.width == reference.width, image.height == reference.height else { return 0 }
        let width = image.width, rows = image.height - shift - cell
        guard rows > 0 else { return 0 }
        var equal = 0
        for y in 0..<rows {
            let rowA = y * width * 4, rowB = (y + shift) * width * 4
            var same = true
            var x = 0
            while x < width * 4 { if abs(Int(a[rowA + x]) - Int(b[rowB + x])) > 8 { same = false; break }; x += 1 }
            if same { equal += 1 }
        }
        return (Double(equal) * 1000 / Double(rows)).rounded() / 1000
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func write() {
        let report: [String: Any] = ["results": results, "displayMaximumHz": window.screen?.maximumFramesPerSecond ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputURL)
        }
    }

    // MARK: Setup

    private func scratchCopy() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-benchmark-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(sourceFile.lastPathComponent)
        try? FileManager.default.copyItem(at: sourceFile, to: copy)
        return copy
    }

    private func focusShell() async -> InteractiveTerminalView? {
        guard let tab = tabs.workspaceTerminalTabs.first else { return nil }
        tabs.selectedTabID = tab.id
        for _ in 0..<100 {
            if let view = window.firstResponder as? InteractiveTerminalView, !(view is CodeTerminalView), !view.isHiddenOrHasHiddenAncestor {
                await sleep(0.3)
                return view
            }
            await sleep(0.05)
        }
        return nil
    }

    private func editorView(timeout: Double) async -> CodeTerminalView? {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let view = tabs.codeSession.terminal, tabs.codeSession.isReady, window.firstResponder === view,
               !view.isHiddenOrHasHiddenAncestor, tabs.selectedTab?.document?.isLoading == false { return view }
            await sleep(0.05)
        }
        return nil
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // MARK: Synthetic input

    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let keyCodes: [Character: UInt16] = {
        var codes: [Character: UInt16] = [" ": 49, "\r": 36, "\u{1B}": 53, ";": 41, "-": 27, "=": 24, ".": 47, ",": 43, "/": 44, "'": 39, "|": 42]
        for (index, letter) in Array("asdfhgzxcv").enumerated() { codes[letter] = UInt16(index) }
        for (letter, code) in zip("bqweryt", [11, 12, 13, 14, 15, 16, 17] as [UInt16]) { codes[letter] = code }
        for (letter, code) in zip("1234659708", [18, 19, 20, 21, 22, 23, 25, 26, 28, 29] as [UInt16]) { codes[letter] = code }
        for (letter, code) in zip("ouipljknm", [31, 32, 34, 35, 37, 38, 40, 45, 46] as [UInt16]) { codes[letter] = code }
        return codes
    }()

    private static func keyEvents(for key: String, windowNumber: Int) -> [NSEvent] {
        var characters = key, ignoring = key
        var modifiers: NSEvent.ModifierFlags = []
        var code = key.first.flatMap { keyCodes[$0] } ?? 0
        if key == downArrow { modifiers = [.function, .numericPad]; code = 125 }
        else if key == "\u{15}" { modifiers = .control; ignoring = "u"; code = 32 }
        else if key == "\u{3}" { modifiers = .control; ignoring = "c"; code = 8 }
        if key == "\r" { characters = "\r"; ignoring = "\r" }
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)
        }
    }

    private func type(count: Int, interval: Double, into view: NSView) async {
        let letters = Array("the quick brown fox jumps over a lazy dog ")
        await postKeys((0..<count).map { String(letters[$0 % letters.count]) }, interval: interval)
    }

    /// Posts on a background timer at fixed times, independent of main-thread work.
    private func postKeys(_ keys: [String], interval: Double) async {
        let windowNumber = window.windowNumber
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var index = 0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: eventQueue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(0))
            timer.setEventHandler {
                guard index < keys.count else { timer.cancel(); done.resume(); return }
                let key = keys[index]; index += 1
                let events = Self.keyEvents(for: key, windowNumber: windowNumber)
                // Real input wakes the main run loop through its event port; a posted event alone
                // waits for the next wake-up. Dispatch it the way the event loop would.
                DispatchQueue.main.async { for event in events { NSApp.sendEvent(event) } }
            }
            timer.resume()
        }
    }

    /// Trackpad-style continuous scrolling at 120 events/s: down the content, then back up.
    /// A synthesized scroll event cannot carry a window-relative location, so each event is
    /// queued on the main thread and handed to the terminal's wheel path after the window
    /// records the interaction, as `WorkspaceWindow.sendEvent` does for real events.
    private func scroll(over view: InteractiveTerminalView, pointsPerEvent: Int32, seconds: Double) async {
        let perDirection = Int(seconds * 120 / 2)
        let steps: [(Int32, Int64)] = [-pointsPerEvent, pointsPerEvent].flatMap { delta in
            (0..<perDirection).map { i -> (Int32, Int64) in (delta, i == 0 ? 1 : (i == perDirection - 1 ? 4 : 2)) }
        }
        let frames = window.frames
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var index = 0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: eventQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .nanoseconds(0))
            timer.setEventHandler {
                guard index < steps.count else { timer.cancel(); done.resume(); return }
                let (delta, phase) = steps[index]; index += 1
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                guard let event = NSEvent(cgEvent: cg) else { return }
                DispatchQueue.main.async { [weak view] in
                    MainActor.assumeIsolated {
                        frames.noteInteraction()
                        view?.deliverWheel(event)
                    }
                }
            }
            timer.resume()
        }
    }
}

/// Main-thread wait times collected by the benchmark's responsiveness probe (main thread only).
private final class StallRecorder: @unchecked Sendable {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}
