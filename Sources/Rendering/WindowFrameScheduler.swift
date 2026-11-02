import AppKit
import QuartzCore
import CoreVideo
import os

/// Native controls retain AppKit's drawing path; one window clock also paces
/// terminal state, GPU submissions, and pending window drawing during interaction.
final class WorkspaceWindow: NSWindow {
    lazy var frames = WindowFrameScheduler(window: self)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Menu shortcuts and text fields are not terminal input and produce no output to wait for.
            if !event.modifierFlags.contains(.command), firstResponder is InteractiveTerminalView {
                frames.noteKeyInput(timestamp: event.timestamp)
            }
            frames.noteInteraction()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .scrollWheel, .magnify, .rotate, .swipe:
            frames.noteInteraction()
        default: break
        }
        super.sendEvent(event)
    }
}

struct FrameTiming {
    private(set) var intervals: [Double] = []
    private(set) var work: [Double] = []
    private var last: Double?
    mutating func record(timestamp: Double, work duration: Double) {
        if let last {
            let interval = timestamp - last
            // A paused/hidden window is not a dropped frame.
            if interval > 0, interval < 0.25 { intervals.append(interval) }
        }
        last = timestamp
        work.append(duration)
        if intervals.count > 600 { intervals.removeFirst(intervals.count - 600) }
        if work.count > 600 { work.removeFirst(work.count - 600) }
    }
    mutating func pause() { last = nil }
    var cadence: Double { intervals.isEmpty ? 0 : Double(intervals.count) / intervals.reduce(0, +) }
    var p95WorkMilliseconds: Double {
        let sorted = work.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
    }
    func lateIntervals(target: Int) -> Int { intervals.filter { $0 > 1.5 / Double(target) }.count }
}

/// What reached the display, measured with `MTLDrawable.presentedTime`: the interval
/// between frames carrying new terminal content, and the time from an input event
/// to the first displayed frame containing the program's response.
struct PresentationTiming {
    private(set) var contentIntervals: [Double] = []
    private(set) var inputLatencies: [Double] = []
    /// Latency stages for answered key presses: event → main thread, → program output
    /// read, → frame submitted, → frame shown.
    private(set) var stages: [String: [Double]] = [:]
    private var lastContent: [ObjectIdentifier: Double] = [:]
    static let capacity = 2_000
    static let stageNames = ["dispatch", "program", "schedule", "display"]

    struct Input { let timestamp: Double; let received: Double }

    mutating func recordContent(_ surface: ObjectIdentifier, presentedAt time: Double, inputs: [Input] = [],
                                outputAt: Double? = nil, submittedAt: Double? = nil) {
        guard time > 0 else { return }
        if let last = lastContent[surface], time > last, time - last < 0.25 {
            contentIntervals.append(time - last)
        }
        lastContent[surface] = time
        for input in inputs where time >= input.timestamp {
            inputLatencies.append(time - input.timestamp)
            guard let outputAt, let submittedAt else { continue }
            let output = max(outputAt, input.received)
            for (name, value) in zip(Self.stageNames, [input.received - input.timestamp, output - input.received,
                                                        submittedAt - output, time - submittedAt]) {
                stages[name, default: []].append(max(0, value))
            }
        }
        if contentIntervals.count > Self.capacity { contentIntervals.removeFirst(contentIntervals.count - Self.capacity) }
        if inputLatencies.count > Self.capacity { inputLatencies.removeFirst(inputLatencies.count - Self.capacity) }
        for name in Self.stageNames {
            if let count = stages[name]?.count, count > Self.capacity { stages[name]?.removeFirst(count - Self.capacity) }
        }
    }
    mutating func pause() { lastContent.removeAll() }
    mutating func reset() { self = PresentationTiming() }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}

@MainActor
final class WindowFrameScheduler {
    private weak var window: NSWindow?
    private var clock: FrameClock?
    private var observers: [NSObjectProtocol] = []
    private var updates: [() -> Void] = []
    private struct Presentation {
        var outputAt: Double?
        let present: () -> Void
    }
    private struct TaggedFrame {
        let surface: ObjectIdentifier
        var inputs: [PresentationTiming.Input]
        var outputAt: Double?
        let submittedAt: Double
    }
    private var pendingPresentations: [ObjectIdentifier: Presentation] = [:]
    private struct Surface {
        let sample: () -> (name: String, count: UInt64)?
    }
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    private var animations: [ObjectIdentifier: (Double) -> Bool] = [:]
    private var activeUntil = 0.0
    private var fallbackScheduled = false
    private let clockFactory: ((NSWindow, Int, @escaping () -> Void) -> FrameClock?)?
    private let visibility: (() -> Bool)?
    private let now: () -> Double
    private(set) var targetRate = 60
    private(set) var isRunning = false
    private(set) var timing = FrameTiming()
    private(set) var presentation = PresentationTiming()
    /// Key events not yet answered by displayed terminal output (event timestamps).
    private var pendingInputs: [PresentationTiming.Input] = []
    private var taggedFrames: [UInt64: TaggedFrame] = [:]
    private var nextTag: UInt64 = 1
    /// Nonzero only while a content presentation closure runs. A surface copies it
    /// into the frame it submits, so the displayed time can be attributed later.
    private(set) var presentationTag: UInt64 = 0
    /// True while presenting a frame that answers a key press, outside animation, at least
    /// 1.5 refresh intervals after the surface's previous frame. Such a frame may skip the
    /// vsync wait: it cannot replace another frame before the display shows it.
    private(set) var presentationMayBypassVsync = false
    private var lastContentPresentation: [ObjectIdentifier: Double] = [:]
    private static let log = OSLog(subsystem: "com.neolink.app", category: "Frames")

    init(window: NSWindow, clockFactory: ((NSWindow, Int, @escaping () -> Void) -> FrameClock?)? = nil,
         visibility: (() -> Bool)? = nil, now: @escaping () -> Double = CACurrentMediaTime) {
        self.window = window
        self.clockFactory = clockFactory; self.visibility = visibility; self.now = now
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        })
        makeClock()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Clock invalidation normally happens on window close, on the main actor.
    }

    static func forWindow(_ window: NSWindow?) -> WindowFrameScheduler? { (window as? WorkspaceWindow)?.frames }
    nonisolated static func rate(for maximum: Int) -> Int { min(120, max(1, maximum)) }
    private var canAnimate: Bool {
        if let visibility { return visibility() }
        guard let window else { return false }
        // A visible window in an inactive app still shows output and scrolls under the
        // pointer; it keeps display pacing. An occluded or minimized one does not.
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func makeClock() {
        clock?.invalidate()
        guard let window else { clock = nil; return }
        targetRate = Self.rate(for: window.screen?.maximumFramesPerSecond ?? 60)
        if let clockFactory {
            clock = clockFactory(window, targetRate) { [weak self] in self?.frame() }
        } else if #available(macOS 14.0, *) {
            clock = WindowDisplayClock(window: window, rate: targetRate) { [weak self] in self?.frame() }
        } else {
            clock = LegacyDisplayClock(window: window) { [weak self] in self?.frame() }
        }
        isRunning = false
    }

    private func windowChanged() {
        makeClock() // Rebind the screen and its refresh rate after a display move.
        if canAnimate { noteInteraction() }
        else { drainWithoutAnimation() }
    }

    func noteInteraction() {
        let now = now()
        // Keep the clock running briefly so the next input's frame is not delayed by a restart.
        activeUntil = max(activeUntil, now + 0.5)
        wake()
    }

    /// Records a key press for input-to-display latency. `timestamp` uses the
    /// `NSEvent.timestamp` time base, which matches `CACurrentMediaTime`.
    func noteKeyInput(timestamp: Double) {
        expireInputs()
        if pendingInputs.count < 64 { pendingInputs.append(.init(timestamp: timestamp, received: now())) }
    }

    /// A key press that produced no output within half a second is not waiting for it, and
    /// later unrelated output must not count as its answer.
    private func expireInputs() {
        let time = now()
        pendingInputs.removeAll { time - $0.received > 0.5 }
    }

    /// Registers a Metal surface for the Performance Monitor's presented-frame counts.
    func register(_ id: ObjectIdentifier, sample: @escaping () -> (name: String, count: UInt64)?) {
        surfaces[id] = Surface(sample: sample)
    }
    func unregister(_ id: ObjectIdentifier) {
        surfaces.removeValue(forKey: id); pendingPresentations.removeValue(forKey: id); lastContentPresentation.removeValue(forKey: id)
    }

    func enqueue(_ update: @escaping () -> Void) {
        updates.append(update)
        activeUntil = max(activeUntil, now() + 0.05)
        wake()
        // Output answering a key press is drawn as soon as it is parsed instead of at the
        // next display callback, up to a refresh interval sooner.
        expireInputs()
        if !pendingInputs.isEmpty { scheduleImmediateFrame() }
    }

    private var immediateScheduled = false
    private var inFrame = false
    private var lastFrameStart = -Double.infinity

    private func scheduleImmediateFrame() {
        guard !immediateScheduled, !inFrame, isRunning else { return }
        immediateScheduled = true
        // After the current batch of output has been parsed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.immediateScheduled = false
            guard self.canAnimate, !self.updates.isEmpty, self.now() - self.lastFrameStart > 0.002 else { return }
            self.frame(immediate: true)
        }
    }

    /// `outputAt` is when program output behind this frame was read; such a frame
    /// answers pending key presses.
    func requestPresentation(_ id: ObjectIdentifier, outputAt: Double? = nil, present: @escaping () -> Void) {
        let output = pendingPresentations[id]?.outputAt ?? outputAt
        pendingPresentations[id] = Presentation(outputAt: output, present: present)
        activeUntil = max(activeUntil, now() + 0.05)
        wake()
    }

    /// Runs `step` once per frame, after terminal updates and before presentation, with
    /// the time the frame will be shown. Returning false ends the animation. A window that
    /// cannot animate finishes it at once by passing `.infinity`.
    func animate(_ id: ObjectIdentifier, step: @escaping (Double) -> Bool) {
        animations[id] = step
        activeUntil = max(activeUntil, now() + 0.05)
        wake()
    }

    private func runAnimations(at time: Double) {
        guard !animations.isEmpty else { return }
        for (id, step) in animations where !step(time) { animations.removeValue(forKey: id) }
        if !animations.isEmpty { activeUntil = max(activeUntil, now() + 0.05) }
    }

    /// Called when a surface's tagged frame was shown (`presentedTime`, host time).
    func framePresented(tag: UInt64, presentedTime: Double) {
        guard let frame = taggedFrames.removeValue(forKey: tag) else { return }
        presentation.recordContent(frame.surface, presentedAt: presentedTime, inputs: frame.inputs,
                                   outputAt: frame.outputAt, submittedAt: frame.submittedAt)
    }

    /// A refused frame keeps its tag on the surface; the next tag inherits its inputs.
    func mergeTag(_ old: UInt64, into new: UInt64) {
        guard old != new, let previous = taggedFrames.removeValue(forKey: old) else { return }
        taggedFrames[new]?.inputs.insert(contentsOf: previous.inputs, at: 0)
        if taggedFrames[new]?.outputAt == nil { taggedFrames[new]?.outputAt = previous.outputAt }
    }

    func resetPresentationTiming() { presentation.reset(); timing = FrameTiming(); pendingInputs.removeAll() }

    /// Frames a surface submitted that have not reached the display yet. Frames older than
    /// 100 ms are not counted: a refused or discarded frame never reports back.
    private func framesInFlight(_ id: ObjectIdentifier, at time: Double) -> Int {
        taggedFrames.values.reduce(0) { $0 + ($1.surface == id && time - $1.submittedAt < 0.1 ? 1 : 0) }
    }

    /// With `throttle`, a surface that already has three frames waiting for the display keeps its
    /// presentation for a later frame. A frame reaches the display about three refreshes after
    /// it is submitted, so three in flight sustain 120 Hz; asking for more would block the main
    /// thread in `nextDrawable` (and input with it) when the display runs slower than the input,
    /// for example while ProMotion lowers its refresh rate.
    private func runContentPresentations(_ batch: [ObjectIdentifier: Presentation], throttle: Bool = true) {
        for (id, item) in batch {
            if throttle, framesInFlight(id, at: now()) >= 3 {
                let output = pendingPresentations[id]?.outputAt ?? item.outputAt
                pendingPresentations[id] = Presentation(outputAt: output, present: pendingPresentations[id]?.present ?? item.present)
                activeUntil = max(activeUntil, now() + 0.05)
                continue
            }
            let tag = nextTag; nextTag &+= 1
            var inputs: [PresentationTiming.Input] = []
            if item.outputAt != nil { inputs = pendingInputs; pendingInputs.removeAll(keepingCapacity: true) }
            let time = now()
            taggedFrames[tag] = TaggedFrame(surface: id, inputs: inputs, outputAt: item.outputAt, submittedAt: time)
            presentationTag = tag
            presentationMayBypassVsync = !inputs.isEmpty && animations.isEmpty
                && time - (lastContentPresentation[id] ?? -.infinity) >= 1.5 / Double(targetRate)
            lastContentPresentation[id] = time
            item.present()
            presentationTag = 0
            presentationMayBypassVsync = false
        }
        if taggedFrames.count > 512 {
            for key in taggedFrames.keys.sorted().prefix(taggedFrames.count - 256) { taggedFrames.removeValue(forKey: key) }
        }
    }

    private func wake() {
        guard canAnimate, let clock else { scheduleFallback(); return }
        guard !isRunning else { return }
        timing.pause()
        isRunning = true
        clock.start()
    }

    private func scheduleFallback() {
        guard !fallbackScheduled else { return }
        fallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fallbackScheduled = false
            if self.canAnimate, self.clock != nil { self.wake() }
            else { self.drainWithoutAnimation() }
        }
    }

    private func drainUpdates() {
        let batch = updates
        updates.removeAll(keepingCapacity: true)
        batch.forEach { $0() }
    }

    private func drainWithoutAnimation() {
        clock?.stop(); isRunning = false; timing.pause(); presentation.pause()
        drainUpdates()
        runAnimations(at: .infinity)
        let presentations = pendingPresentations
        pendingPresentations.removeAll(keepingCapacity: true)
        // Each surface checks visibility. Background output must still update
        // terminal state; an occluded window must not run a 120 Hz loop.
        runContentPresentations(presentations, throttle: false)
    }

    /// `immediate` frames present output answering input between display callbacks.
    /// They leave animations, cached re-presentation and cadence statistics to the clock.
    private func frame(immediate: Bool = false) {
        guard canAnimate else { drainWithoutAnimation(); return }
        let start = now()
        inFrame = true
        defer { inFrame = false }
        lastFrameStart = start
        os_signpost(.begin, log: Self.log, name: immediate ? "Window.ImmediateFrame" : "Window.Frame")
        drainUpdates()
        if !immediate { runAnimations(at: clock?.targetTimestamp ?? start + 1 / Double(targetRate)) }
        let presentations = pendingPresentations
        pendingPresentations.removeAll(keepingCapacity: true)
        // Unchanged surfaces are not presented again. Repeating a frame after input keeps
        // ProMotion at its top rate, but each repeat queues a drawable ahead of the next
        // real one: measured here it added about 9 ms from key press to display and
        // blocked the main thread in nextDrawable.
        runContentPresentations(presentations)
        window?.displayIfNeeded()
        let duration = now() - start
        os_signpost(.end, log: Self.log, name: immediate ? "Window.ImmediateFrame" : "Window.Frame")
        guard !immediate else { return }
        timing.record(timestamp: start, work: duration)
        if start >= activeUntil && updates.isEmpty && pendingPresentations.isEmpty && animations.isEmpty {
            clock?.stop(); isRunning = false; timing.pause()
        }
    }

    var summary: String {
        let p = PresentationTiming.percentile
        func ms(_ value: Double) -> String { String(format: "%.1f", value * 1000) }
        let latencies = presentation.inputLatencies.suffix(200), content = presentation.contentIntervals.suffix(600)
        let latency = latencies.isEmpty ? "type in a terminal or the editor to measure"
            : "p50 \(ms(p(Array(latencies), 0.5))) ms · p95 \(ms(p(Array(latencies), 0.95))) ms (last \(latencies.count) keys)"
        let cadence = content.isEmpty ? "–" : "p50 \(ms(p(Array(content), 0.5))) ms · p95 \(ms(p(Array(content), 0.95))) ms"
        return """
        Window target: \(targetRate) Hz · \(isRunning ? "active" : "idle")
        Display callbacks: \(String(format: "%.1f", timing.cadence))/s · late \(timing.lateIntervals(target: targetRate))/\(timing.intervals.count)
        Frame work, p95: \(String(format: "%.2f", timing.p95WorkMilliseconds)) ms

        Key press → frame on screen: \(latency)
        Interval between new terminal frames on screen: \(cadence)

        Both use the time each frame reached the display (MTLDrawable.presentedTime). Key latency starts at the event's timestamp and excludes keyboard and panel hardware. Frame intervals reflect how often content changed, so they are long while typing and 8.3 ms during smooth scrolling at 120 Hz. Idle windows pause their clock.
        """
    }

    var gpuSamples: [ObjectIdentifier: (name: String, count: UInt64)] {
        surfaces.compactMapValues { $0.sample() }
    }

    func invalidate() {
        clock?.invalidate(); clock = nil; isRunning = false
        drainUpdates(); pendingPresentations.removeAll(); surfaces.removeAll(); animations.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
}

@MainActor
protocol FrameClock: AnyObject {
    func start()
    func stop()
    func invalidate()
    /// When the frame being prepared will be shown, if the clock knows it.
    var targetTimestamp: Double? { get }
}

extension FrameClock {
    var targetTimestamp: Double? { nil }
}

@available(macOS 14.0, *)
@MainActor
private final class WindowDisplayClock: FrameClock {
    private var link: CADisplayLink?
    init(window: NSWindow, rate: Int, tick: @escaping () -> Void) {
        // The link retains its target, so use a separate callback object whose
        // closure captures the scheduler weakly, not the clock itself.
        let target = DisplayTarget(tick: tick)
        let link = window.displayLink(target: target, selector: #selector(DisplayTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    deinit { link?.invalidate() }
    func start() { link?.isPaused = false }
    func stop() { link?.isPaused = true }
    func invalidate() { link?.invalidate(); link = nil }
    var targetTimestamp: Double? { link.map { $0.targetTimestamp } }
}

@available(macOS 14.0, *)
@MainActor
private final class DisplayTarget: NSObject {
    private let tick: () -> Void
    init(tick: @escaping () -> Void) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { tick() }
}

/// Ventura fallback: the realtime display callback only signals a coalescing
/// dispatch source. AppKit, terminal parsing and drawing stay on the main thread.
@MainActor
private final class LegacyDisplayClock: FrameClock {
    private var link: CVDisplayLink?
    private var source: DispatchSourceUserDataAdd?
    init?(window: NSWindow, tick: @escaping () -> Void) {
        guard let display = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(display.uint32Value, &link) == kCVReturnSuccess, let link else { return nil }
        let source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { tick() } }
        guard CVDisplayLinkSetOutputHandler(link, { _, _, _, _, _ in source.add(data: 1); return kCVReturnSuccess }) == kCVReturnSuccess else { return nil }
        source.resume()
        self.source = source; self.link = link
    }
    func start() { if let link { CVDisplayLinkStart(link) } }
    func stop() { if let link { CVDisplayLinkStop(link) } }
    func invalidate() { stop(); link = nil; source?.cancel(); source = nil }
    deinit {
        if let link { CVDisplayLinkStop(link) }
        source?.cancel()
    }
}
