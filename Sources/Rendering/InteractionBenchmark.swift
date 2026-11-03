import AppKit
import Darwin
import ImageIO
import QuartzCore
import SwiftTerm

/// Developer benchmark, inactive unless `NEOLINK_BENCHMARK` is set (see docs/RENDERING.md).
///
/// Synthetic key and trackpad events are generated on a background timer at fixed times,
/// independent of main-thread work, and dispatched through AppKit, the terminal's wheel path
/// and the PTY like real input. Results come from the window's frame scheduler: display-link
/// callbacks, `presentedTime` of every terminal drawable, whether that frame changed, and for
/// scrolling the position each frame drew compared with the ideal finger motion.
/// `scripts/bench-run.py` repeats runs and rejects those where the screen locked or NeoLink
/// lost the foreground.
@MainActor
final class InteractionBenchmark {
    private let window: WorkspaceWindow
    private let tabs: TabsController
    private let scenarios: [String]
    private let outputURL: URL
    private let sourceFile: URL
    private var results: [[String: Any]] = []
    private var environment: [String: Any] = [:]
    private let eventQueue = DispatchQueue(label: "com.neolink.benchmark.events", qos: .userInteractive)
    private let launched = CACurrentMediaTime()

    static func startIfRequested(window: WorkspaceWindow, tabs: TabsController) {
        let env = ProcessInfo.processInfo.environment
        guard let names = env["NEOLINK_BENCHMARK"], !names.isEmpty else { return }
        if names.contains("capture") || names.contains("pixels") { TerminalView.allowsMetalFrameCapture = true }
        let output = URL(fileURLWithPath: env["NEOLINK_BENCHMARK_OUTPUT"] ?? "/tmp/neolink-benchmark.json")
        let source = URL(fileURLWithPath: env["NEOLINK_BENCHMARK_FILE"]
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
        // Enter the native full-screen Space before preparing fixtures. Clicking a
        // changing accessibility tree mid-setup can minimize the wrong window.
        if ProcessInfo.processInfo.environment["NEOLINK_WINDOW"] == "fullscreen" {
            window.toggleFullScreen(nil)
            await sleep(2)
            guard window.styleMask.contains(.fullScreen), window.isKeyWindow else {
                fail("setup", "native full-screen window did not become key")
                write()
                tabs.shutdownAgents(); tabs.codeSession.shutdown()
                exit(1)
            }
        }
        // Surrounding-UI scenarios need a project. A development build may not resolve the
        // installed app's folder bookmarks; use the checkout and restore the setting at the end.
        let savedProject = UserDefaults.standard.string(forKey: "activeProjectPath")
        if scenarios.contains(where: { $0.hasPrefix("ui-") || $0 == "render-motion" }), WorkspaceAccess.shared.projectURL == nil {
            WorkspaceAccess.shared.select(Self.repositoryRoot)
            await sleep(1.0)
        }
        var editorFile: URL?
        func editor() async -> CodeTerminalView? {
            if let editorFile { tabs.openFile(editorFile) } // Selects its existing tab.
            else { let file = scratchCopy(); editorFile = file; tabs.openFile(file) }
            guard let view = await editorView(timeout: 10) else { return nil }
            await sleep(0.8)
            return view
        }
        for scenario in scenarios {
            switch scenario {
            case "render-motion":
                // A repeatable animation workload, not synthesized mouse/keyboard input.
                // This isolates real drawable delivery from the frequency of input events.
                guard let shell = await focusShell(), let scroll = Self.explorerScrollView(in: window),
                      let table = scroll.documentView as? ExplorerNSTableView, let coordinator = table.coordinator else {
                    fail(scenario, "shell or native explorer unavailable"); continue
                }
                // The same expanded fixture must scroll even at the full Retina height.
                // Expanding only Sources leaves fewer rows than a 16-inch viewport.
                for name in ["Sources", "Documents", "FileBrowser", "Rendering", "Tests"] {
                    if let row = coordinator.rows.first(where: { $0.name == name && !$0.expanded && $0.item.isDirectory }) {
                        coordinator.parent.onToggle(row)
                        await sleep(0.3)
                    }
                }
                await sleep(1)
                guard let surface = Self.find(ExplorerMetalView.self, in: scroll, where: { _ in true }),
                      await wait(8, { surface.isCoveringNativeRows }) else { fail(scenario, "explorer Metal surface did not present"); continue }
                // Same-binary A/B for the retained GPU compositor; this is a developer
                // benchmark option, never a persisted user preference.
                surface.usesCachedComposition = ProcessInfo.processInfo.environment["NEOLINK_EXPLORER_COMPOSITION"] != "0"
                let range = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                guard range > 100 else { fail(scenario, "explorer needs more expanded rows"); continue }
                shell.feed(text: "\u{1B}[2J\u{1B}[H" + (1...1000).map { "\($0) GPU motion abcdefghijklmnopqrstuvwxyz 0123456789" }.joined(separator: "\r\n"))
                _ = shell.scrollViewport(towardTop: 100)
                shell.smoothScrollSource = .scrollback
                await sleep(0.5)
                var renderCPU: [Double] = [], renderGPU: [Double] = [], renderQueue: [Double] = []
                var explorerCPU: [Double] = [], explorerGPU: [Double] = []
                surface.frameProfile = { cpu, gpu in explorerCPU.append(cpu); explorerGPU.append(gpu) }
                shell.metalFrameProfile = { cpu, gpu, queue in
                    renderCPU.append(cpu); renderGPU.append(gpu); renderQueue.append(queue)
                }
                surface.recordsMotionSamples = true
                let oldBuilds = surface.compositionBuilds, oldReuses = surface.compositionReuses
                let start = CACurrentMediaTime(), oldFallbacks = surface.nativeFallbacks
                let oldDrawableCounters = shell.rendering.drawableCounters
                await measure(scenario, extra: {
                    let samples = surface.motionSamples.filter { $0.time >= start && $0.changed }
                    let intervals = zip(samples, samples.dropFirst()).map { $1.time - $0.time }
                    func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
                    return ["inputDriver": "procedural animation, no input injection",
                            "explorerCompositionEnabled": surface.usesCachedComposition,
                            "explorerRenderCPUms": ["p50": ms(PresentationTiming.percentile(explorerCPU, 0.5)), "p95": ms(PresentationTiming.percentile(explorerCPU, 0.95)), "total": ms(explorerCPU.reduce(0, +))],
                            "explorerRenderGPUms": ["p50": ms(PresentationTiming.percentile(explorerGPU, 0.5)), "p95": ms(PresentationTiming.percentile(explorerGPU, 0.95)), "total": ms(explorerGPU.reduce(0, +))],
                            "terminalRenderCPUms": ["p50": ms(PresentationTiming.percentile(renderCPU, 0.5)), "p95": ms(PresentationTiming.percentile(renderCPU, 0.95)), "max": ms(renderCPU.max() ?? 0)],
                            "terminalRenderGPUms": ["p50": ms(PresentationTiming.percentile(renderGPU, 0.5)), "p95": ms(PresentationTiming.percentile(renderGPU, 0.95)), "max": ms(renderGPU.max() ?? 0)],
                            "terminalGPUQueueMs": ["p50": ms(PresentationTiming.percentile(renderQueue, 0.5)), "p95": ms(PresentationTiming.percentile(renderQueue, 0.95)), "max": ms(renderQueue.max() ?? 0)],
                            "terminalDrawableCounters": shell.rendering.drawableCounters.merging(oldDrawableCounters) { current, old in current - old },
                            "explorerChangedFrames": samples.count,
                            "explorerCompositionBuilds": surface.compositionBuilds - oldBuilds,
                            "explorerCompositionReuses": surface.compositionReuses - oldReuses,
                            "explorerPresentedIntervalMs": ["p50": ms(PresentationTiming.percentile(intervals, 0.5)),
                                "p95": ms(PresentationTiming.percentile(intervals, 0.95)), "max": ms(intervals.max() ?? 0)],
                            "explorerNativeFallbacks": surface.nativeFallbacks - oldFallbacks,
                            "explorerFrameSamples": samples.map { ["time": $0.time, "y": $0.y] }]
                }) {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        self.window.frames.animate(ObjectIdentifier(self)) { time in
                            let elapsed = CACurrentMediaTime() - start
                            guard time.isFinite, elapsed < 5 else { done.resume(); return false }
                            let phase = (elapsed * 0.8).truncatingRemainder(dividingBy: 2)
                            let triangle = phase < 1 ? phase : 2 - phase
                            shell.smoothScrollOffset = CGFloat(triangle * 100 - 50)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: range * CGFloat(triangle)))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            return true
                        }
                    }
                }
                surface.recordsMotionSamples = false
                surface.frameProfile = nil
                shell.metalFrameProfile = nil
                shell.smoothScrollOffset = 0
            case "manual-motion":
                // Passive capture: all input comes from the user or an external UI driver.
                // Do not focus controls, send keys/wheel events, or alter the project here.
                let seconds = min(180, max(5, Double(ProcessInfo.processInfo.environment["NEOLINK_BENCHMARK_SECONDS"] ?? "60") ?? 60))
                let sampler = Self.explorerScrollView(in: window).map { ScrollPositionSampler(scrollView: $0, window: window) }
                sampler?.start()
                await measure(scenario, extra: {
                    var report: [String: Any] = ["inputDriver": "external", "continuousScrollBenchmark": false,
                                               "scope": "manual input; geometry is not pixel presentation"]
                    report["terminalScrollFrames"] = self.window.frames.presentation.scrollSamples.map {
                        ["presented": $0.presented, "inputLines": $0.input, "drawnLines": $0.drawn]
                    }
                    if let sampler { report["explorerGeometry"] = sampler.report() }
                    return report
                }) { await self.sleep(seconds) }
                sampler?.stop()
            case "idle":
                // Nothing changes on screen: the clock and the GPU should stay quiet.
                await sleep(1.5)
                await measure(scenario) { await self.sleep(5) }
            case "terminal-type":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await measure(scenario, expectKeys: 75) { await self.type(count: 75, interval: 1.0 / 25, into: view) }
                await postKeys(["\u{15}"], interval: 0.05) // Ctrl-U clears the typed line.
            case "terminal-scroll", "terminal-flick":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await postKeys(Array("clear; seq 1 6000\r").map(String.init), interval: 0.01)
                await sleep(1.5)
                // The viewport starts at the newest output: scroll back first, then forward.
                let profile = scenario == "terminal-flick" ? ScrollProfile.flick(towardTop: true) : .steady(pointsPerSecond: 720, seconds: 2.5, towardTopFirst: true)
                await measureScroll(scenario, view: view, profile: profile)
            case "terminal-flood":
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await postKeys(Array("clear; yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -n 3000000\r").map(String.init), interval: 0.01)
                await measure(scenario) { await self.sleep(3) }
                await postKeys(["\u{3}"], interval: 0.05) // Ctrl-C
                _ = view
            case "terminal-flood-type":
                // Typing while another command floods the same terminal.
                guard let view = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                await postKeys(Array("clear; yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -n 3000000\r").map(String.init), interval: 0.01)
                await sleep(0.5)
                await measure(scenario) { await self.type(count: 50, interval: 1.0 / 25, into: view) }
                await postKeys(["\u{3}"], interval: 0.05)
                await sleep(0.5)
                await postKeys(["\u{15}", "c", "l", "e", "a", "r", "\r"], interval: 0.05)
            case "editor-open":
                let file = scratchCopy()
                editorFile = file
                self.environment["footprintBeforeFirstOpenMB"] = (Self.footprintMB() * 10).rounded() / 10
                await measure(scenario) {
                    let started = CACurrentMediaTime()
                    self.tabs.openFile(file)
                    _ = await self.editorView(timeout: 10)
                    self.environment["editorReadyAfterOpenMs"] = ((CACurrentMediaTime() - started) * 10_000).rounded() / 10
                    self.environment["editorReadyAfterLaunchMs"] = ((CACurrentMediaTime() - self.launched) * 10_000).rounded() / 10
                    // The first frame the editor presents after it is shown.
                    let deadline = CACurrentMediaTime() + 3
                    while PhaseTrace.moments["editor.firstFrameAfterShown"] == nil, CACurrentMediaTime() < deadline { await self.sleep(0.005) }
                    let origin = PhaseTrace.moments["open.begin"] ?? started
                    self.environment["firstOpenPhasesMs"] = PhaseTrace.moments.filter { $0.key.hasPrefix("open.") || $0.key.hasPrefix("editor.") }
                        .mapValues { (($0 - origin) * 10_000).rounded() / 10 }
                    await self.sleep(1.5)
                    self.environment["footprintAfterFirstOpenMB"] = (Self.footprintMB() * 10).rounded() / 10
                }
            case "editor-scroll", "editor-slow", "editor-flick", "editor-reversal":
                guard let view = await editor() else { fail(scenario, "editor did not open"); continue }
                await home(view)
                let profile: ScrollProfile
                switch scenario {
                case "editor-slow": profile = .steady(pointsPerSecond: 60, seconds: 3, towardTopFirst: false)
                case "editor-flick": profile = .flick(towardTop: false)
                case "editor-reversal": profile = .reversal()
                default: profile = .steady(pointsPerSecond: 720, seconds: 2.5, towardTopFirst: false)
                }
                await measureScroll(scenario, view: view, profile: profile)
            case "editor-pixels", "editor-pixels-steady", "editor-pixels-reversal":
                guard let view = await editor() else { fail(scenario, "editor did not open"); continue }
                await home(view)
                let profile: ScrollProfile = scenario == "editor-pixels" ? .flick(towardTop: false)
                    : scenario == "editor-pixels-reversal" ? .reversal() : .steady(pointsPerSecond: 720, seconds: 2.5, towardTopFirst: false)
                await measurePixels(scenario, view: view, profile: profile)
            case "editor-type":
                guard let view = await editor() else { fail(scenario, "editor did not open"); continue }
                await measure(scenario, expectKeys: 75) { await self.type(count: 75, interval: 1.0 / 25, into: view) }
            case "editor-cursor":
                guard let view = await editor() else { fail(scenario, "editor did not open"); continue }
                await postKeys(["\u{1B}", "g", "g", "i"], interval: 0.05) // Normal mode, top, insert.
                await sleep(0.5)
                await measure(scenario, expectKeys: 400) { await self.postKeys(Array(repeating: Self.downArrow, count: 400), interval: 0.010) }
                _ = view
            case "editor-capture":
                guard let view = await editor() else { fail(scenario, "editor did not open"); continue }
                await captureSmoothScroll(view)
            case "ui-tabs":
                // Rapid switches between two editor tabs and the shell.
                guard await editor() != nil, let firstEditor = tabs.selectedTabID,
                      let shellTab = tabs.workspaceTerminalTabs.first?.id else { fail(scenario, "editor did not open"); continue }
                tabs.openFile(scratchCopy())
                guard await editorView(timeout: 10) != nil, let secondEditor = tabs.selectedTabID, secondEditor != firstEditor else {
                    fail(scenario, "second editor did not open"); continue
                }
                await sleep(0.8)
                var latencies: [Double] = []
                await measure(scenario, extra: { ["switchToFocusedMs": Self.summary(latencies), "switches": latencies.count] }) {
                    let order = [shellTab, firstEditor, secondEditor, firstEditor]
                    for index in 0..<24 {
                        let target = order[index % order.count]
                        let started = CACurrentMediaTime()
                        self.tabs.selectedTabID = target
                        while CACurrentMediaTime() - started < 1, !self.isShowing(target) { await self.sleep(0.002) }
                        latencies.append(CACurrentMediaTime() - started)
                        await self.sleep(0.12)
                    }
                }
            case "ui-resize":
                // Drag the divider beside the explorer back and forth for two seconds; the
                // shell reflows and its program redraws at every width.
                guard let shell = await focusShell() else { fail(scenario, "no shell terminal"); continue }
                let agentPanel = tabs.showAgentPanel
                tabs.showAgentPanel = false
                await sleep(0.8)
                guard let split = window.contentView.flatMap({ Self.find(NSSplitView.self, in: $0) { $0.isVertical && $0.subviews.count >= 2 } }) else {
                    fail(scenario, "no split view"); tabs.showAgentPanel = agentPanel; continue
                }
                let start = split.subviews[0].frame.maxX
                var widths = Set<Int>()
                await measure(scenario, extra: { ["terminalColumnsSeen": widths.count] }) {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        var frame = 0
                        self.window.frames.animate(ObjectIdentifier(split)) { time in
                            frame += 1
                            guard time.isFinite, frame <= 240 else { done.resume(); return false }
                            let offset = 70 * (1 - cos(Double(frame) / 120 * .pi)) // Out and back, twice.
                            split.setPosition(start + offset, ofDividerAt: 0)
                            widths.insert(shell.getTerminal().cols)
                            return true
                        }
                    }
                    await self.sleep(0.3)
                }
                split.setPosition(start, ofDividerAt: 0)
                tabs.showAgentPanel = agentPanel
            case "ui-acp-stream":
                // An agent answer streams into the right panel while the shell keeps focus.
                guard await focusShell() != nil, let python = CommandRunner.executable("python3") else { fail(scenario, "no shell or python3"); continue }
                let script = Self.repositoryRoot.appendingPathComponent("scripts/fixtures/acp-agent.py")
                do { try tabs.openACP(CodingAgent(name: "Fixture", executable: python, arguments: [script.path]), in: Self.repositoryRoot) }
                catch { fail(scenario, error.localizedDescription); continue }
                guard let session = tabs.selectedACP, await wait(10, { session.isReady && !session.isBusy }) else {
                    fail(scenario, "agent did not connect"); tabs.shutdownAgents(); continue
                }
                _ = await focusShell()
                await measure(scenario, extra: { ["streamedCharacters": session.messages.last?.text.count ?? 0] }) {
                    session.send("stream")
                    _ = await self.wait(20) { !session.isBusy }
                }
                tabs.closeACP(session.id)
            case "ui-pdf":
                // Scroll a 40-page PDF with the trackpad.
                guard let pdf = Self.makePDF(pages: 40) else { fail(scenario, "could not create a PDF"); continue }
                tabs.openFile(pdf)
                guard await wait(10, { self.tabs.selectedTab?.document?.pdfView?.window != nil }),
                      let pdfView = tabs.selectedTab?.document?.pdfView,
                      let scroll = Self.find(NSScrollView.self, in: pdfView, where: { _ in true }) else { fail(scenario, "PDF did not open"); continue }
                await sleep(0.8)
                let before = scroll.contentView.bounds.origin.y
                await measure(scenario, extra: { ["scrolledPoints": Int(abs(scroll.contentView.bounds.origin.y - before))] }) {
                    _ = await self.play(.steady(pointsPerSecond: 1200, seconds: 2, towardTopFirst: false), cell: 16) { scroll.scrollWheel(with: $0) }
                }
                if let id = tabs.selectedTabID { tabs.closeTab(id, discardingChanges: true) }
                try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
            case "ui-explorer":
                // Reveal a deeply nested file (expands and loads its ancestors), then filter the tree.
                guard WorkspaceAccess.shared.projectURL != nil else { fail(scenario, "no project folder"); continue }
                guard let field = window.contentView.flatMap({ Self.find(NSTextField.self, in: $0) { $0.placeholderString == "Filter tree…" } }) else {
                    fail(scenario, "explorer filter not visible"); continue
                }
                let deep = Self.repositoryRoot.appendingPathComponent("Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift")
                await measure(scenario) {
                    self.tabs.openFile(deep)
                    await self.sleep(1.2)
                    self.window.makeFirstResponder(field)
                    await self.postKeys(Array("render").map(String.init), interval: 0.12)
                    await self.sleep(0.6)
                    await self.postKeys(Array(repeating: "\u{7F}", count: 6), interval: 0.12)
                    await self.sleep(0.6)
                }
                if let id = tabs.selectedTabID { tabs.closeTab(id, discardingChanges: true) }
            case "ui-explorer-scroll":
                // Exercise native explorer geometry. Position samples establish movement,
                // not correct pixel presentation or perceived trackpad smoothness.
                guard WorkspaceAccess.shared.projectURL != nil else { fail(scenario, "no project folder"); continue }
                UserDefaults.standard.set(true, forKey: "showFileBrowser")
                UserDefaults.standard.set(false, forKey: "showConnectionsSidebar")
                // Open deep files so the tree reveals and expands many folders, making it long.
                for path in ["Sources/Rendering/InteractionBenchmark.swift", "Vendor/SwiftTerm/Sources/SwiftTerm/Terminal.swift",
                             "Tests/NeoLinkTests/FrameSchedulingTests.swift", "Sources/Agents/ACPSession.swift",
                             "Sources/FileBrowser/LocalFileBrowserView.swift"] {
                    self.tabs.openFile(Self.repositoryRoot.appendingPathComponent(path))
                    await self.sleep(0.5)
                }
                await self.sleep(1.0)
                guard let explorerScroll = Self.explorerScrollView(in: window) else { fail(scenario, "explorer scroll view not found"); continue }
                self.environment["explorerVisibleRows"] = (explorerScroll.documentView?.frame.height ?? 0) / 24
                let scrollSampler = ScrollPositionSampler(scrollView: explorerScroll, window: window)
                await measure(scenario, extra: { scrollSampler.report() }) {
                    scrollSampler.start()
                    _ = await self.play(.steady(pointsPerSecond: 1000, seconds: 2.5, towardTopFirst: false), cell: 20) { explorerScroll.scrollWheel(with: $0) }
                    scrollSampler.stop()
                }
            case "ui-quick-open", "ui-git":
                // In-window overlays (not AppKit sheets): Quick Open filtering the project's files,
                // and the Git review loading status and a diff. Measured by main-thread stalls.
                guard WorkspaceAccess.shared.projectURL != nil else { fail(scenario, "no project folder"); continue }
                _ = await focusShell()
                await measure(scenario) {
                    if scenario == "ui-quick-open" { NotificationCenter.default.post(name: .neoLinkQuickOpen, object: nil) }
                    else { NotificationCenter.default.post(name: .neoLinkShowGit, object: Self.repositoryRoot) }
                    // Wait for the overlay's search field (Quick Open) or the Git "Done" button.
                    let placeholder = scenario == "ui-quick-open" ? "Find a file by name or path…" : nil
                    guard await self.wait(3, {
                        self.window.contentView.flatMap { c in
                            placeholder != nil
                                ? Self.find(NSTextField.self, in: c) { $0.placeholderString == placeholder } != nil
                                : Self.find(NSButton.self, in: c) { $0.title == "Done" } != nil
                        } ?? false
                    }) else { return }
                    await self.sleep(scenario == "ui-quick-open" ? 0.6 : 2.0)
                    if scenario == "ui-quick-open", let field = self.window.contentView.flatMap({ Self.find(NSTextField.self, in: $0) { $0.placeholderString == "Find a file by name or path…" } }) {
                        self.window.makeFirstResponder(field)
                        await self.postKeys(Array("metalrender").map(String.init), interval: 0.1)
                        await self.sleep(0.8)
                    }
                    // Escape to the main window closes the overlay.
                    await self.postKeys(["\u{1B}"], interval: 0.05)
                    await self.sleep(0.5)
                }
            default:
                fail(scenario, "unknown scenario")
            }
            await sleep(0.8)
        }
        write()
        tabs.shutdownAgents(); tabs.codeSession.shutdown()
        if let editorFile { try? FileManager.default.removeItem(at: editorFile.deletingLastPathComponent()) }
        if let savedProject { UserDefaults.standard.set(savedProject, forKey: "activeProjectPath") }
        else { UserDefaults.standard.removeObject(forKey: "activeProjectPath") }
        UserDefaults.standard.synchronize()
        exit(0)
    }

    // MARK: Measurement

    private func measure(_ name: String, expectKeys: Int? = nil, extra: (() -> [String: Any])? = nil,
                         _ body: () async -> Void) async {
        let frames = window.frames
        frames.resetPresentationTiming()
        let started = CACurrentMediaTime(), cpuStart = Self.cpuSeconds()
        // Main-thread responsiveness: a background timer queues a block every 2 ms and
        // records how long each waited. A long wait is a stall of input and drawing.
        let probe = DispatchSource.makeTimerSource(flags: .strict, queue: eventQueue)
        let stalls = SampleRecorder()
        probe.schedule(deadline: .now(), repeating: 0.002, leeway: .nanoseconds(0))
        probe.setEventHandler {
            let queued = CACurrentMediaTime()
            DispatchQueue.main.async { stalls.record(CACurrentMediaTime() - queued, at: queued) }
        }
        probe.resume()
        // Validity: the window must stay key, visible and unlocked for the whole scenario.
        var problems = Set<String>()
        let validity = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A sheet of the window (Quick Open, Git review) may be key instead.
                if !NSApp.isActive || !(self.window.isKeyWindow || self.window.attachedSheet?.isKeyWindow == true) { problems.insert("lost foreground") }
                if !self.window.occlusionState.contains(.visible) { problems.insert("window occluded") }
                if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { problems.insert("screen locked") }
            }
        }
        RunLoop.main.add(validity, forMode: .common)
        await body()
        await sleep(0.35) // Let the last frames reach the display.
        probe.cancel(); validity.invalidate()
        let elapsed = CACurrentMediaTime() - started, cpu = Self.cpuSeconds() - cpuStart
        let timing = frames.timing, presented = frames.presentation
        let p = PresentationTiming.percentile
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        func stats(_ values: [Double]) -> [String: Double] {
            ["p50": ms(p(values, 0.5)), "p95": ms(p(values, 0.95)), "p99": ms(p(values, 0.99)), "max": ms(values.max() ?? 0)]
        }
        let late = timing.intervals.filter { $0 > 1.5 / Double(frames.targetRate) }.count
        let contentLate = presented.contentIntervals.filter { $0 > 1.5 / Double(frames.targetRate) }.count
        var result: [String: Any] = [
            "scenario": name, "seconds": ms(elapsed) / 1000, "targetHz": frames.targetRate,
            "clockCallbacks": timing.intervals.count,
            "clockIntervalMs": stats(timing.intervals),
            "clockLatePercent": timing.intervals.isEmpty ? 0 : (Double(late) * 1000 / Double(timing.intervals.count)).rounded() / 10,
            "frameWorkMs": ["p95": ms(p(timing.work, 0.95)), "max": ms(timing.work.max() ?? 0)],
            "presentedFrames": presented.presentedFrames, "unchangedFrames": presented.unchangedFrames,
            "discardedFrames": presented.discardedFrames,
            "contentFrames": presented.contentIntervals.count,
            "contentIntervalMs": stats(presented.contentIntervals),
            "contentLatePercent": presented.contentIntervals.isEmpty ? 0 : (Double(contentLate) * 1000 / Double(presented.contentIntervals.count)).rounded() / 10,
            "missedRefreshes": presented.missedRefreshes(rate: frames.targetRate),
            "mainThreadStallMs": ["p99": ms(p(stalls.values, 0.99)), "max": ms(stalls.values.max() ?? 0),
                                  "over8ms": stalls.values.filter { $0 > 1.0 / 120 }.count,
                                  "over16ms": stalls.values.filter { $0 > 1.0 / 60 }.count],
            // The five longest waits: [ms after the scenario began, ms waited].
            "longestStalls": zip(stalls.times, stalls.values).sorted { $0.1 > $1.1 }.prefix(5).map { [ms($0.0 - started), ms($0.1)] },
            "cpuPercent": (cpu / max(elapsed, 0.001) * 1000).rounded() / 10,
            "footprintMB": (Self.footprintMB() * 10).rounded() / 10,
            "keyAnswered": presented.answeredInputs, "keyUnmatched": presented.unmatchedInputs,
            "raw": ["keyLatencySamplesMs": presented.inputLatencies.map(ms),
                    "contentIntervalSamplesMs": presented.contentIntervals.map(ms),
                    "stallSamplesMs": stalls.values.filter { $0 > 0.004 }.map(ms)],
        ]
        if !presented.inputLatencies.isEmpty {
            result["keyToDisplayMs"] = stats(presented.inputLatencies).merging(["count": Double(presented.inputLatencies.count)]) { a, _ in a }
            result["keyStagesMedianMs"] = Dictionary(uniqueKeysWithValues: PresentationTiming.stageNames.map {
                ($0, ms(p(presented.stages[$0] ?? [], 0.5)))
            })
        }
        if let expectKeys, presented.answeredInputs < expectKeys * 9 / 10 {
            problems.insert("only \(presented.answeredInputs) of \(expectKeys) keys answered")
        }
        if let extra { result.merge(extra()) { _, new in new } }
        if !problems.isEmpty { result["invalid"] = problems.sorted() }
        results.append(result)
        print("NeoLink benchmark", name, result.filter { $0.key != "raw" && $0.key != "explorerFrameSamples" })
    }

    private func fail(_ name: String, _ reason: String) { results.append(["scenario": name, "error": reason]) }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    // MARK: Scrolling

    /// A trackpad gesture: one event per 1/120 s with a delta in points (positive moves the
    /// content toward the top) and its gesture and momentum phases.
    struct ScrollProfile {
        struct Event { var delta: Double; var phase: Int64; var momentum: Int64 }
        var events: [Event]

        /// Constant finger speed in one direction, then the other.
        static func steady(pointsPerSecond: Double, seconds: Double, towardTopFirst: Bool) -> ScrollProfile {
            let perDirection = Int(seconds * 60), step = pointsPerSecond / 120
            let first = towardTopFirst ? step : -step
            let events = [first, -first].flatMap { delta in
                (0..<perDirection).map { i in Event(delta: delta, phase: i == 0 ? 1 : (i == perDirection - 1 ? 4 : 2), momentum: 0) }
            }
            return ScrollProfile(events: events)
        }

        /// A quick swipe, then macOS-style momentum decaying by a constant factor per event.
        static func flick(towardTop: Bool) -> ScrollProfile {
            let sign = towardTop ? 1.0 : -1.0
            var events: [Event] = [8, 16, 22, 24, 22].enumerated().map { i, d in Event(delta: sign * d, phase: i == 0 ? 1 : 2, momentum: 0) }
            events.append(Event(delta: 0, phase: 4, momentum: 0))
            var delta = 20.0
            var first = true
            while delta > 0.25 {
                events.append(Event(delta: sign * delta, phase: 0, momentum: first ? 1 : 2))
                delta *= 0.965; first = false
            }
            events.append(Event(delta: 0, phase: 0, momentum: 3))
            return ScrollProfile(events: events)
        }

        /// Down, then up again within one gesture.
        static func reversal() -> ScrollProfile {
            var events: [Event] = []
            for i in 0..<60 { events.append(Event(delta: -5, phase: i == 0 ? 1 : 2, momentum: 0)) }
            for _ in 0..<60 { events.append(Event(delta: 5, phase: 2, momentum: 0)) }
            events.append(Event(delta: 0, phase: 4, momentum: 0))
            return ScrollProfile(events: events)
        }
    }

    /// Delivers a profile and returns the ideal content position over time: (time, lines toward the top).
    private func play(_ profile: ScrollProfile, on view: InteractiveTerminalView) async -> [(Double, Double)] {
        await play(profile, cell: Double(cellPoints(view))) { [weak view] event in view?.deliverWheel(event) }
    }

    /// Delivers a profile's scroll events on the main thread at 120 Hz to `deliver`.
    private func play(_ profile: ScrollProfile, cell: Double, deliver: @escaping @MainActor (NSEvent) -> Void) async -> [(Double, Double)] {
        let frames = window.frames
        let timeline = TimelineRecorder()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var index = 0, position = 0.0, carried = 0.0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: eventQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .nanoseconds(0))
            timer.setEventHandler {
                guard index < profile.events.count else { timer.cancel(); done.resume(); return }
                let step = profile.events[index]; index += 1
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
                // AppKit reports synthesized continuous deltas in whole points; carry the
                // fraction so the delivered total matches the profile. The ideal position
                // below stays continuous, so the comparison includes this ±0.5 pt rounding.
                carried += step.delta
                let whole = carried.rounded(.towardZero)
                carried -= whole
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: whole)
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: whole)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: step.momentum)
                position += step.delta / cell
                timeline.append(CACurrentMediaTime(), position)
                guard let event = NSEvent(cgEvent: cg) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        frames.noteInteraction()
                        deliver(event)
                    }
                }
            }
            timer.resume()
        }
        await sleep(0.4) // Settling.
        return timeline.values
    }

    private func measureScroll(_ name: String, view: InteractiveTerminalView, profile: ScrollProfile) async {
        var timeline: [(Double, Double)] = []
        var start: (input: Double, drawn: Double)?
        var since = 0.0
        await measure(name, extra: {
            var report = ScrollAnalysis(timeline: timeline, samples: self.window.frames.presentation.scrollSamples, origin: start,
                                        rate: self.window.frames.targetRate,
                                        cellPixels: Double(self.cellPoints(view) * (view.window?.backingScaleFactor ?? 2))).report
            // Requests to a full-screen program against the scrolls it performed.
            let log = view.smoothScrollRequests
            let requests = log.requests.filter { $0.time >= since }, moves = log.moves.filter { $0.time >= since }
            if !requests.isEmpty {
                let lastInput = timeline.last?.0 ?? since
                let requested: Int = requests.reduce(0) { $0 + $1.lines }
                let scrolled: Int = moves.reduce(0) { $0 + $1.lines }
                let late: Int = moves.filter { $0.time > lastInput + 0.05 }.reduce(0) { $0 + $1.lines }
                let lastMs: Double = ((moves.last.map { $0.time - lastInput } ?? 0) * 10_000).rounded() / 10
                var program: [String: Any] = ["requestedLines": requested, "scrolledLines": scrolled, "requests": requests.count]
                program["scrolls"] = moves.count
                program["scrolledAfterInputEnded"] = late
                program["lastScrollAfterInputMs"] = lastMs
                report["program"] = program
            }
            return report
        }) {
            start = view.scrollTraceSample() ?? (0, 0)
            since = CACurrentMediaTime()
            timeline = await self.play(profile, on: view)
        }
    }

    /// Per-frame motion against the ideal finger position. A displayed frame is a stall when the
    /// content stayed put while the finger moved, and a jump when it moved over twice as far as the
    /// finger did in that refresh plus a quarter line (a catch-up after a stall or a whole-line
    /// correction). Positions are compared after removing the best constant latency, so the
    /// remaining error is unevenness, not delay.
    struct ScrollAnalysis {
        let timeline: [(Double, Double)]
        let samples: [PresentationTiming.ScrollSample]
        let origin: (input: Double, drawn: Double)?
        let rate: Int
        let cellPixels: Double

        func ideal(at time: Double) -> Double {
            guard let first = timeline.first else { return 0 }
            if time <= first.0 { return 0 }
            guard let index = timeline.firstIndex(where: { $0.0 >= time }) else { return timeline.last!.1 }
            let (t1, p1) = timeline[index], (t0, p0) = index > 0 ? timeline[index - 1] : (first.0, 0)
            return t1 > t0 ? p0 + (p1 - p0) * (time - t0) / (t1 - t0) : p1
        }

        var report: [String: Any] {
            guard let origin, let start = timeline.first?.0, let end = timeline.last?.0, samples.count > 2 else {
                return ["scroll": ["frames": samples.count]]
            }
            let frames = samples.filter { $0.presented >= start }.map { ($0.presented, $0.drawn - origin.drawn) }
            guard frames.count > 2 else { return ["scroll": ["frames": frames.count]] }
            // Best constant latency in 0–80 ms.
            var lag = 0.0, best = Double.infinity
            for candidate in stride(from: 0.0, through: 0.08, by: 0.001) {
                let error = frames.filter { $0.0 <= end + 0.02 }.reduce(0) { $0 + pow($1.1 - ideal(at: $1.0 - candidate), 2) }
                if error < best { best = error; lag = candidate }
            }
            var stalls = 0, jumps = 0, velocityErrors: [Double] = [], positionErrors: [Double] = []
            for i in 1..<frames.count where frames[i].0 <= end + lag {
                let dt = frames[i].0 - frames[i - 1].0
                let drawn = frames[i].1 - frames[i - 1].1
                let expected = ideal(at: frames[i].0 - lag) - ideal(at: frames[i - 1].0 - lag)
                positionErrors.append(abs(frames[i].1 - ideal(at: frames[i].0 - lag)))
                if dt > 0 { velocityErrors.append(abs(drawn - expected) / dt) }
                if abs(expected) > 0.02, abs(drawn) < 0.1 * abs(expected) { stalls += 1 }
                if abs(drawn) > 2 * abs(expected) + 0.25 { jumps += 1 }
            }
            // Settling after the last input event: how long, how far, and in which direction.
            let lastDirection = (timeline.last!.1 - (timeline.dropLast(5).last?.1 ?? 0)).sign
            let atEnd = frames.last(where: { $0.0 <= end + lag })?.1 ?? frames.last!.1
            let after = frames.filter { $0.0 > end + lag }
            var settleEnd = end + lag
            for i in after.indices.dropFirst() where abs(after[i].1 - after[i - 1].1) > 0.002 { settleEnd = after[i].0 }
            let settleDistance = (frames.last!.1 - atEnd)
            // Refreshes skipped while the finger moved at least one device pixel per refresh.
            let period = 1 / Double(rate), pixel = 1 / max(1, cellPixels)
            var missedMoving = 0
            for i in 1..<frames.count where frames[i].0 <= end + lag {
                let gap = frames[i].0 - frames[i - 1].0
                guard gap > 1.5 * period else { continue }
                let moved = abs(ideal(at: frames[i].0 - lag) - ideal(at: frames[i - 1].0 - lag))
                if moved / (gap / period) >= pixel { missedMoving += Int((gap / period).rounded()) - 1 }
            }
            let p = PresentationTiming.percentile
            func r(_ v: Double, _ digits: Double = 1000) -> Double { (v * digits).rounded() / digits }
            return ["scroll": [
                "frames": frames.count, "lagMs": r(lag * 1000, 10),
                "stallFrames": stalls, "jumpFrames": jumps,
                "positionErrorLinesP95": r(p(positionErrors, 0.95)), "positionErrorLinesMax": r(positionErrors.max() ?? 0),
                "velocityErrorP95": r(p(velocityErrors, 0.95), 10),
                "settleMs": r((settleEnd - end - lag) * 1000, 10), "settleLines": r(settleDistance),
                "settleReversal": abs(settleDistance) > 0.02 && settleDistance.sign != lastDirection ? 1 : 0,
                "idealLines": r(timeline.last!.1), "drawnLines": r(frames.last!.1),
                "receivedLines": r((samples.last?.input ?? origin.input) - origin.input),
                "missedRefreshesWhileMoving": missedMoving,
                "samples": samples.filter { $0.presented >= start }.map {
                    [r(($0.presented - start) * 1000, 10), r($0.input - origin.input), r($0.drawn - origin.drawn)]
                },
            ]]
        }
    }

    // MARK: Consecutive-frame pixel analysis

    /// Captures every frame of a flick and measures each frame's displacement from its pixels:
    /// the vertical shift that best maps the previous frame's rows onto this frame's. Compares
    /// it with the displacement the scroll model reports and counts rows that match neither
    /// (stale, blank or misplaced rows other than the newly exposed edge and the cursor).
    private func measurePixels(_ name: String, view: InteractiveTerminalView, profile: ScrollProfile) async {
        let scale = view.window?.backingScaleFactor ?? 2
        let cellPx = Int((cellPoints(view) * scale).rounded())
        let cellWidthPx = max(1, view.cellSizeInPixels(source: view.getTerminal())?.width ?? 16)
        let hashes = PixelFrames()
        var drawnByTag: [UInt64: Double] = [:]
        var cursorByTag: [UInt64: Int] = [:]
        window.frames.frameDrawnObserver = { [weak view] tag, _, scroll in
            if let scroll { drawnByTag[tag] = scroll.drawn }
            // Runs right after the frame was encoded, before the terminal changes again.
            if let view { cursorByTag[tag] = view.getTerminal().getCursorLocation().x }
        }
        let analysis = DispatchQueue(label: "com.neolink.benchmark.pixels")
        let keepImages = ProcessInfo.processInfo.environment["NEOLINK_BENCHMARK_KEEP_FRAMES"].flatMap(Int.init) ?? 0
        let output = outputURL
        view.metalFrameCaptureEveryFrame = { image, tag in
            guard let image else { return }
            analysis.async {
                hashes.append(tag: tag, rows: Self.rowHashes(image, bandWidth: cellWidthPx))
                if hashes.frames.count <= keepImages {
                    Self.writePNG(image, to: output.deletingPathExtension().appendingPathExtension("\(name)-\(hashes.frames.count - 1).png"))
                }
            }
        }
        await measure(name) { _ = await self.play(profile, on: view) }
        view.metalFrameCaptureEveryFrame = nil
        window.frames.frameDrawnObserver = nil
        let frames: [(tag: UInt64, rows: FrameRows)] = analysis.sync { hashes.frames }
        var compared = 0, disagreements = 0, artifactFrames = 0, worstUnmatched = 0, cursorHops = 0
        var pairs: [[Int]] = []
        for i in 1..<max(1, frames.count) {
            let a = frames[i - 1], b = frames[i]
            guard let drawnA = drawnByTag[a.tag], let drawnB = drawnByTag[b.tag] else { continue }
            // Content moving toward the top (drawn increasing) moves pixels down.
            let expected = Int(((drawnB - drawnA) * Double(cellPx)).rounded())
            // The editor's status line (last cell row) is fixed and changes with the cursor position.
            let rows = max(0, b.rows.full.count - cellPx)
            let (shift, unmatched) = Self.bestShift(Array(a.rows.full.prefix(rows)), Array(b.rows.full.prefix(rows)), limit: 3 * cellPx, near: expected)
            // Neovim keeps its cursor inside the window, so it hops between lines while the
            // content scrolls; the cells it left and entered are not scrolling artifacts.
            var masked = Set<Int>()
            for column in [cursorByTag[a.tag], cursorByTag[b.tag]].compactMap({ $0 }) { masked.formUnion([column - 1, column, column + 1]) }
            let unexplained = Self.unexplainedRows(a.rows, b.rows, rows: rows, shift: shift, maskedBands: masked)
            compared += 1
            pairs.append([expected, shift, unmatched, unexplained])
            if abs(shift - expected) > 1 { disagreements += 1 }
            // Allow the newly exposed edge plus one partly drawn new line.
            let allowance = abs(shift) + cellPx
            if unexplained > allowance { artifactFrames += 1; worstUnmatched = max(worstUnmatched, unexplained - allowance) }
            if unmatched > allowance, unexplained <= allowance { cursorHops += 1 }
        }
        if let index = results.lastIndex(where: { $0["scenario"] as? String == name }) {
            results[index]["pixels"] = ["capturedFrames": frames.count, "comparedPairs": compared,
                                        "shiftDisagreesWithModel": disagreements, "framesWithUnexpectedRows": artifactFrames,
                                        "worstUnexpectedPixelRows": worstUnmatched, "cellPixels": cellPx,
                                        "pairsWithOnlyCursorHops": cursorHops,
                                        "pairsExpectedMeasuredUnmatchedUnexplained": pairs]
        }
    }

    /// Row hashes of a frame, whole rows (nil for rows of a single color, which match at any
    /// shift) and per band of `bandWidth` pixel columns (one terminal cell wide).
    nonisolated private static func rowHashes(_ image: CGImage, bandWidth: Int) -> FrameRows {
        guard let bytes = pixels(image) else { return FrameRows(full: [], bands: []) }
        let stride = image.width * 4, bandCount = max(1, image.width / bandWidth)
        let seed: UInt64 = 1469598103934665603, prime: UInt64 = 1099511628211
        var full: [UInt64?] = [], bands: [[UInt64]] = []
        full.reserveCapacity(image.height); bands.reserveCapacity(image.height)
        for y in 0..<image.height {
            let base = y * stride
            var hash = seed, uniform = true
            var rowBands = [UInt64](repeating: seed, count: bandCount)
            for x in 0..<stride {
                let value = bytes[base + x]
                hash = (hash ^ UInt64(value)) &* prime
                let band = min(bandCount - 1, x / 4 / bandWidth)
                rowBands[band] = (rowBands[band] ^ UInt64(value)) &* prime
                if uniform, value != bytes[base + x % 4] { uniform = false }
            }
            full.append(uniform ? nil : hash)
            bands.append(rowBands)
        }
        return FrameRows(full: full, bands: bands)
    }

    /// Non-uniform rows of `b` that match neither the row `shift` pixels above in `a` (moved
    /// with the content) nor the same row (fixed), ignoring the bands in `maskedBands`.
    nonisolated private static func unexplainedRows(_ a: FrameRows, _ b: FrameRows, rows: Int, shift: Int, maskedBands: Set<Int>) -> Int {
        func matches(_ ya: Int, _ yb: Int) -> Bool {
            guard ya >= 0, ya < rows, ya < a.full.count else { return false }
            if a.full[ya] == b.full[yb] { return true }
            let bandsA = a.bands[ya], bandsB = b.bands[yb]
            for band in 0..<min(bandsA.count, bandsB.count) where !maskedBands.contains(band) && bandsA[band] != bandsB[band] {
                return false
            }
            return true
        }
        var count = 0
        for y in 0..<min(rows, b.full.count) where b.full[y] != nil {
            if !matches(y - shift, y), !matches(y, y) { count += 1 }
        }
        return count
    }

    /// The shift `s` (pixels; content moved down by `s`) maximizing rows where b[y] == a[y - s],
    /// preferring the one nearest `near` on ties, and the number of non-uniform rows that matched nothing.
    nonisolated private static func bestShift(_ a: [UInt64?], _ b: [UInt64?], limit: Int, near: Int) -> (Int, Int) {
        guard a.count == b.count, !a.isEmpty else { return (0, 0) }
        var best = (shift: 0, matches: -1)
        for shift in -limit...limit {
            var matches = 0
            for y in max(0, shift)..<min(b.count, a.count + shift) {
                if let value = b[y], value == a[y - shift] { matches += 1 }
            }
            if matches > best.matches || (matches == best.matches && abs(shift - near) < abs(best.shift - near)) {
                best = (shift, matches)
            }
        }
        // Rows that neither moved with the content nor stayed put (fixed rows such as a status line).
        var unexplained = 0
        for y in 0..<b.count {
            guard let value = b[y] else { continue }
            let moved = y - best.shift >= 0 && y - best.shift < a.count && a[y - best.shift] == value
            if !moved, a[y] != value { unexplained += 1 }
        }
        return (best.shift, unexplained)
    }

    // MARK: Smooth-scroll capture

    /// Scrolls the editor by part of a line and compares the frame drawn mid-scroll with the
    /// frame before it, shifted by the same distance. Writes the frames as PNG for inspection.
    private func captureSmoothScroll(_ view: InteractiveTerminalView) async {
        await home(view)
        let scale = view.window?.backingScaleFactor ?? 2
        let cell = cellPoints(view)
        guard let before = await capture(view) else { fail("editor-capture", "no frame"); return }
        var rows: [[String: Any]] = []
        for fraction in [0.25, 0.5, 0.75] {
            let points = (cell * CGFloat(fraction) * scale).rounded() / scale
            wheel(view, deltaY: -points, phase: 1)
            await sleep(0.02)
            guard let mid = await capture(view) else { continue }
            wheel(view, deltaY: 0, phase: 4)
            await sleep(0.5) // Settles to the next whole line.
            guard let after = await capture(view) else { continue }
            let shift = Int((points * scale).rounded())
            let match = Self.compare(mid, before, shift: shift, height: Int(cell * scale))
            let afterMatch = Self.compare(after, before, shift: Int((cell * scale).rounded()), height: Int(cell * scale))
            rows.append(["fraction": fraction, "shiftPx": shift, "midMatchesShiftedBefore": match, "afterMatchesOneLine": afterMatch])
            for (name, image) in [("before", before), ("mid-\(fraction)", mid), ("after-\(fraction)", after)] {
                Self.writePNG(image, to: outputURL.deletingPathExtension().appendingPathExtension("\(name).png"))
            }
            await home(view)
        }
        results.append(["scenario": "editor-capture", "comparisons": rows])
        print("NeoLink benchmark capture", rows)
    }

    /// Normal mode, top of the file, cursor on line 11, insert mode.
    private func home(_ view: InteractiveTerminalView) async {
        await postKeys(["\u{1B}", "g", "g", "1", "0", "j", "i"], interval: 0.05)
        await sleep(0.6)
    }

    private func cellPoints(_ view: InteractiveTerminalView) -> CGFloat {
        CGFloat(view.cellSizeInPixels(source: view.getTerminal())?.height ?? 32) / (view.window?.backingScaleFactor ?? 2)
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

    nonisolated private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func write() {
        let shell = window.contentView.flatMap { Self.find(InteractiveTerminalView.self, in: $0) { !($0 is CodeTerminalView) } }
        let editor = tabs.codeSession.terminal
        var setup = environment
        let processStart = PhaseTrace.processStart
        setup["launchPhasesMs"] = PhaseTrace.moments.filter { $0.key.hasPrefix("launch.") || $0.key.hasPrefix("shell.") }
            .mapValues { (($0 - processStart) * 10_000).rounded() / 10 }
        setup.merge([
            "displayMaximumHz": window.screen?.maximumFramesPerSecond ?? 0,
            "backingScale": window.backingScaleFactor,
            "nativeFullScreen": window.styleMask.contains(.fullScreen),
            "windowPoints": "\(Int(window.frame.width))x\(Int(window.frame.height))",
            "fontPointSize": TextSizePreferences.shared.pointSize,
            "shellGrid": shell.map { "\($0.getTerminal().cols)x\($0.getTerminal().rows)" } ?? "",
            "editorGrid": editor.map { "\($0.getTerminal().cols)x\($0.getTerminal().rows)" } ?? "",
            "editorAlternateScreen": editor?.isDisplayingAlternateScreen ?? false,
            "editorMouseReporting": editor.map { $0.allowMouseReporting && $0.getTerminal().mouseMode != .off } ?? false,
            "gpuRendering": TerminalRenderingPreferences.shared.useGPU,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ]) { _, new in new }
        let report: [String: Any] = ["results": results, "setup": setup, "displayMaximumHz": window.screen?.maximumFramesPerSecond ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputURL)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool) -> T? {
        if let view = view as? T, match(view) { return view }
        for child in view.subviews { if let found = find(type, in: child, where: match) { return found } }
        return nil
    }

    /// Collects every view of a type that matches, anywhere under `view`.
    private static func findAll<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> [T] {
        var found: [T] = []
        if let view = view as? T, match(view) { found.append(view) }
        for child in view.subviews { found += findAll(type, in: child, where: match) }
        return found
    }

    /// The file-explorer's scroll view, in either the List (NSTableView-backed) or the older
    /// ScrollView layout: the left-most on-screen NSScrollView tall enough to be the tree and
    /// not inside a terminal surface.
    private static func explorerScrollView(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        func insideTerminal(_ view: NSView) -> Bool {
            var node: NSView? = view
            while let current = node {
                if current is InteractiveTerminalView { return true }
                node = current.superview
            }
            return false
        }
        let candidates = findAll(NSScrollView.self, in: content) { scroll in
            scroll.frame.height > 100 && scroll.window != nil && !insideTerminal(scroll)
        }
        return candidates.min { a, b in
            a.convert(a.bounds, to: content).minX < b.convert(b.bounds, to: content).minX
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

    /// Polls `condition` every 2 ms until it holds or `timeout` passes.
    private func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { return false }
            await sleep(0.002)
        }
        return true
    }

    /// Whether `tabID` is selected, its view is shown and has keyboard focus.
    private func isShowing(_ tabID: UUID) -> Bool {
        guard tabs.selectedTabID == tabID, let tab = tabs.tabs.first(where: { $0.id == tabID }) else { return false }
        if tab.document?.usesNeovim == true {
            guard let view = tabs.codeSession.terminal else { return false }
            return tabs.codeSession.requestedPath == nil && window.firstResponder === view && !view.isHiddenOrHasHiddenAncestor
        }
        guard tab.terminal != nil, let view = window.firstResponder as? InteractiveTerminalView else { return false }
        return !(view is CodeTerminalView) && !view.isHiddenOrHasHiddenAncestor
    }

    /// Percentiles in milliseconds.
    private static func summary(_ values: [Double]) -> [String: Double] {
        let p = PresentationTiming.percentile
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        return ["p50": ms(p(values, 0.5)), "p95": ms(p(values, 0.95)), "max": ms(values.max() ?? 0)]
    }

    /// The source checkout this build came from (benchmarks use its fixtures and files).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A text PDF in a new temporary folder.
    private static func makePDF(pages: Int) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-benchmark-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Benchmark.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for page in 1...pages {
            context.beginPDFPage(nil)
            for line in 0..<60 {
                let text = NSAttributedString(string: "Page \(page), line \(line): the quick brown fox jumps over the lazy dog 0123456789",
                                              attributes: [.font: font])
                context.textPosition = CGPoint(x: 48, y: 750 - CGFloat(line) * 12)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Synthetic keys

    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let keyCodes: [Character: UInt16] = {
        var codes: [Character: UInt16] = [" ": 49, "\r": 36, "\u{1B}": 53, "\u{7F}": 51, ";": 41, "-": 27, "=": 24, ".": 47, ",": 43, "/": 44, "'": 39, "|": 42]
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
    private func postKeys(_ keys: [String], interval: Double, to target: NSWindow? = nil) async {
        let windowNumber = (target ?? window).windowNumber
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
}

/// Samples a scroll view's position on every display refresh during a scroll, so a benchmark
/// can tell whether the content actually moved each refresh. The terminal's presentedTime path
/// does not cover AppKit/SwiftUI views like the explorer, Git diff or agent transcript; this
/// does. It rides the window's existing frame clock (CADisplayLink on macOS 14+, CVDisplayLink
/// below), the same clock the terminals pace on.
@MainActor
final class ScrollPositionSampler {
    private let scrollView: NSScrollView
    private let frames: WindowFrameScheduler?
    private var positions: [(time: Double, y: Double)] = []
    private var running = false
    private let rate: Int

    init(scrollView: NSScrollView, window: NSWindow) {
        self.scrollView = scrollView
        self.frames = WindowFrameScheduler.forWindow(window)
        self.rate = self.frames?.targetRate ?? min(120, window.screen?.maximumFramesPerSecond ?? 60)
    }

    func start() {
        positions.removeAll()
        running = true
        frames?.animate(ObjectIdentifier(self)) { [weak self] _ in
            guard let self, self.running else { return false }
            self.positions.append((CACurrentMediaTime(), self.scrollView.contentView.bounds.origin.y))
            return true
        }
    }

    func stop() { running = false }

    func report() -> [String: Any] { ScrollGeometryMetrics.report(positions, rate: rate) }
}

/// Geometry sampling is deliberately separate from drawable/pixel measurements.
struct ScrollGeometryMetrics {
    static func report(_ positions: [(time: Double, y: Double)], rate: Int) -> [String: Any] {
        let period = 1.0 / Double(max(1, rate))
        let changes = positions.indices.dropFirst().filter { abs(positions[$0].y - positions[$0 - 1].y) > 0.01 }
        var travel = 0.0, repeated = 0, longestStill = 0.0, longestSampleGap = 0.0
        for index in positions.indices.dropFirst() {
            travel += abs(positions[index].y - positions[index - 1].y)
            longestSampleGap = max(longestSampleGap, positions[index].time - positions[index - 1].time)
        }
        if let first = changes.first, let last = changes.last {
            var lastChange = positions[first].time
            for index in first...last {
                if abs(positions[index].y - positions[index - 1].y) > 0.01 {
                    longestStill = max(longestStill, positions[index].time - lastChange - period)
                    lastChange = positions[index].time
                } else { repeated += 1 }
            }
        }
        let range = (positions.map(\.y).max() ?? 0) - (positions.map(\.y).min() ?? 0)
        func r(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        var result: [String: Any] = [
            "scrollSamples": positions.count, "scrollRefreshesMoved": changes.count,
            "scrollRefreshesRepeatedWhileMoving": repeated,
            "scrollStutterPercent": changes.count + repeated > 0 ? r(Double(repeated) * 100 / Double(changes.count + repeated)) : 0,
            "scrollLongestStillMs": r(max(0, longestStill) * 1000),
            "scrollLongestSampleGapMs": r(longestSampleGap * 1000),
            "scrollTravelPoints": r(travel), "scrollRangePoints": r(range),
            "scrollExpectedRefreshMs": r(period * 1000),
            "scrollMeasurementScope": "clip-view geometry, not presented pixels or visual smoothness"
        ]
        if positions.count < 20 || changes.count < 20 || travel < 100 || range < 50 {
            result["invalid"] = ["Insufficient explorer movement; input did not establish a scrolling workload."]
        }
        return result
    }

}

/// Values recorded by one thread and read after it is done (benchmark only).
private final class SampleRecorder: @unchecked Sendable {
    private(set) var values: [Double] = []
    /// When each value's measurement began (`CACurrentMediaTime`), for values that record one.
    private(set) var times: [Double] = []
    func record(_ value: Double) { values.append(value) }
    func record(_ value: Double, at time: Double) { values.append(value); times.append(time) }
}

private final class TimelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Double, Double)] = []
    func append(_ time: Double, _ position: Double) { lock.lock(); storage.append((time, position)); lock.unlock() }
    var values: [(Double, Double)] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Row hashes of one captured frame: whole rows, and per cell-wide band of each row.
private struct FrameRows {
    let full: [UInt64?]
    let bands: [[UInt64]]
}

/// Row hashes of captured frames, appended on the analysis queue.
private final class PixelFrames: @unchecked Sendable {
    private(set) var frames: [(tag: UInt64, rows: FrameRows)] = []
    func append(tag: UInt64, rows: FrameRows) { frames.append((tag, rows)) }
}
