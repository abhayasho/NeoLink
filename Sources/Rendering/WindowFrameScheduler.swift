import AppKit
import QuartzCore
import CoreVideo
import Metal
import os

/// Native controls retain AppKit's drawing path; one window clock also paces
/// terminal state, GPU submissions, and pending window drawing during interaction.
final class WorkspaceWindow: NSWindow {
    lazy var frames = WindowFrameScheduler(window: self)
    var gpuWorkspace: NeoGPUWorkspace?
    var gpuOverlayPresented = false

    @MainActor func installGPUWorkspace() {
        guard #available(macOS 14, *), gpuWorkspace == nil,
              ProcessInfo.processInfo.environment["NEOLINK_GPUI_WORKSPACE"] != "0",
              let device = MTLCreateSystemDefaultDevice() else { return }
        gpuWorkspace = NeoGPUWorkspace(window: self, device: device)
        gpuWorkspace?.setSuspended(gpuOverlayPresented)
        if gpuWorkspace != nil { NotificationCenter.default.post(name: .neoGPUWorkspaceReady, object: self) }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Menu shortcuts and text fields are not terminal input and produce no output to wait for.
            if !event.modifierFlags.contains(.command), let terminal = firstResponder as? InteractiveTerminalView {
                frames.noteKeyInput(timestamp: event.timestamp, surface: ObjectIdentifier(terminal))
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
    mutating func record(timestamp: Double, work duration: Double, includeLongIntervals: Bool = false) {
        if let last {
            let interval = timestamp - last
            // A paused/hidden window is not a dropped frame.
            if interval > 0, includeLongIntervals || interval < 0.25 { intervals.append(interval) }
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
    /// Drawables that reached the display, those identical to the surface's previous frame,
    /// and those the compositor never showed.
    private(set) var presentedFrames = 0
    private(set) var unchangedFrames = 0
    private(set) var discardedFrames = 0
    /// Key presses answered by output of the surface that had focus, and those that expired
    /// unanswered (no output from that surface within 0.5 s).
    private(set) var answeredInputs = 0
    private(set) var unmatchedInputs = 0
    /// Per displayed frame of a scrolling surface: when it was shown, where the input had
    /// moved the content, and where the frame drew it (lines toward the top).
    private(set) var scrollSamples: [ScrollSample] = []
    private var lastContent: [ObjectIdentifier: Double] = [:]
    static let capacity = 4_000
    static let stageNames = ["dispatch", "program", "schedule", "display"]

    struct Input { let timestamp: Double; let received: Double }
    struct ScrollSample { let presented: Double; let input: Double; let drawn: Double }

    mutating func recordFrame(_ surface: ObjectIdentifier, presentedAt time: Double, changed: Bool = true,
                              inputs: [Input] = [], outputAt: Double? = nil, submittedAt: Double? = nil,
                              scroll: (input: Double, drawn: Double)? = nil) {
        guard time > 0 else { discardedFrames += 1; return }
        presentedFrames += 1
        if changed {
            if let last = lastContent[surface], time > last, time - last < 0.25 {
                contentIntervals.append(time - last)
            }
            lastContent[surface] = time
        } else {
            unchangedFrames += 1
        }
        if let scroll { scrollSamples.append(ScrollSample(presented: time, input: scroll.input, drawn: scroll.drawn)) }
        for input in inputs where time >= input.timestamp {
            answeredInputs += 1
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
        if scrollSamples.count > Self.capacity { scrollSamples.removeFirst(scrollSamples.count - Self.capacity) }
        for name in Self.stageNames {
            if let count = stages[name]?.count, count > Self.capacity { stages[name]?.removeFirst(count - Self.capacity) }
        }
    }
    mutating func recordUnmatched(_ count: Int) { unmatchedInputs += count }
    mutating func pause() { lastContent.removeAll() }
    mutating func reset() { self = PresentationTiming() }

    /// Refreshes with no new content while content was changing: intervals beyond 1.5 refreshes,
    /// counted as the refreshes they spanned minus one.
    func missedRefreshes(rate: Int) -> Int {
        let period = 1 / Double(rate)
        return contentIntervals.reduce(0) { $0 + ($1 > 1.5 * period ? Int(($1 / period).rounded()) - 1 : 0) }
    }

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
    private var drawableUpdates: [ObjectIdentifier: [() -> Void]] = [:]
    private var drawableDrivers: [ObjectIdentifier: () -> Void] = [:]
    private struct Presentation {
        var outputAt: Double?
        let present: () -> Void
    }
    private struct TaggedFrame {
        let surface: ObjectIdentifier
        var inputs: [PresentationTiming.Input]
        var outputAt: Double?
        let submittedAt: Double
        var changed = true
        var scroll: (input: Double, drawn: Double)?
    }
    private var pendingPresentations: [ObjectIdentifier: Presentation] = [:]
    private struct Surface {
        let sample: () -> (name: String, count: UInt64)?
        let interaction: (() -> Void)?
        let changedCount: (() -> UInt64)?
    }
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    private struct Animation {
        let surface: ObjectIdentifier?
        let step: (Double) -> Bool
    }
    private var animations: [ObjectIdentifier: Animation] = [:]
    private var activeUntil = 0.0
    private var fallbackScheduled = false
    private let clockFactory: ((NSWindow, Int, @escaping () -> Void) -> FrameClock?)?
    private let visibility: (() -> Bool)?
    private let now: () -> Double
    private(set) var targetRate = 60
    private(set) var isRunning = false
    private(set) var timing = FrameTiming()
    private(set) var presentation = PresentationTiming()
    /// Key events not yet answered, per terminal surface that had focus when they arrived.
    /// Only that surface's output answers them; output from another terminal or agent does not.
    private var pendingInputs: [ObjectIdentifier: [PresentationTiming.Input]] = [:]
    private var taggedFrames: [UInt64: TaggedFrame] = [:]
    private var nextTag: UInt64 = 1
    /// Nonzero only while a content presentation closure runs. A surface copies it
    /// into the frame it submits, so the displayed time can be attributed later.
    private(set) var presentationTag: UInt64 = 0
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
            clock = NativeDisplayClock(window: window) { [weak self] in self?.frame() }
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
        // Keep the clock running for 1 second following interaction to request high refresh during a gesture. ProMotion remains OS-controlled.
        activeUntil = max(activeUntil, now + 1.0)
        for surface in surfaces.values { surface.interaction?() }
        wake()
    }

    /// Records a key press for input-to-display latency. `timestamp` uses the
    /// `NSEvent.timestamp` time base, which matches `CACurrentMediaTime`.
    func noteKeyInput(timestamp: Double, surface: ObjectIdentifier) {
        expireInputs()
        if pendingInputs[surface, default: []].count < 64 {
            pendingInputs[surface, default: []].append(.init(timestamp: timestamp, received: now()))
        }
    }

    /// A key press that produced no output within half a second is not waiting for it, and
    /// later unrelated output must not count as its answer. Expired presses are counted.
    private func expireInputs() {
        let time = now()
        for (surface, inputs) in pendingInputs {
            let kept = inputs.filter { time - $0.received <= 0.5 }
            if kept.count != inputs.count { presentation.recordUnmatched(inputs.count - kept.count) }
            pendingInputs[surface] = kept.isEmpty ? nil : kept
        }
    }

    /// Registers a Metal surface for the Performance Monitor's presented-frame counts.
    func register(_ id: ObjectIdentifier, interaction: (() -> Void)? = nil, changedCount: (() -> UInt64)? = nil,
                  sample: @escaping () -> (name: String, count: UInt64)?) {
        surfaces[id] = Surface(sample: sample, interaction: interaction, changedCount: changedCount)
    }
    func unregister(_ id: ObjectIdentifier) {
        surfaces.removeValue(forKey: id); pendingPresentations.removeValue(forKey: id)
        for (key, animation) in animations where animation.surface == id {
            animations.removeValue(forKey: key)
            _ = animation.step(.infinity)
        }
        setDrawableDriver(id, wake: nil)
    }

    /// A Metal surface owns its update + presentation deadline. Do not make its
    /// state wait for the independent window clock before it can use a drawable.
    func setDrawableDriver(_ id: ObjectIdentifier, wake: (() -> Void)?) {
        drawableDrivers[id] = wake
        if wake == nil {
            drawableUpdates.removeValue(forKey: id)?.forEach { $0() }
            if hasDrawableAnimation(id) { self.wake() }
        }
    }

    func prepareDrawable(_ id: ObjectIdentifier, at time: Double? = nil) {
        let batch = drawableUpdates.removeValue(forKey: id) ?? []
        batch.forEach { $0() }
        runAnimations(at: time ?? now(), surface: id)
    }

    func hasDrawableAnimation(_ id: ObjectIdentifier) -> Bool {
        animations.values.contains { $0.surface == id }
    }

    /// `surface` is the terminal whose output produced the update.
    func enqueue(from surface: ObjectIdentifier? = nil, _ update: @escaping () -> Void) {
        if canAnimate, let surface, let request = drawableDrivers[surface] {
            drawableUpdates[surface, default: []].append(update)
            request()
            return
        }
        updates.append(update)
        activeUntil = max(activeUntil, now() + 0.05)
        wake()
        // Output answering a key press is drawn as soon as it is parsed instead of at the
        // next display callback, up to a refresh interval sooner.
        expireInputs()
        if let surface, pendingInputs[surface] != nil { scheduleImmediateFrame() }
    }

    private var workspaceDriver: (() -> Void)?

    /// The workspace drawable owns the latch deadline while hosted. Keep the
    /// native clock for overlays, older systems and renderer failure.
    func setWorkspaceDriver(_ wake: (() -> Void)?) {
        clock?.stop(); isRunning = false; timing.pause()
        workspaceDriver = wake
        if wake != nil || !updates.isEmpty || !animations.isEmpty || !pendingPresentations.isEmpty { self.wake() }
    }

    func prepareWorkspace(at time: Double) {
        guard workspaceDriver != nil else { return }
        frame(targetTimestamp: time)
    }

    private var immediateScheduled = false
    private var inFrame = false
    private var lastFrameStart = -Double.infinity

    private func scheduleImmediateFrame() {
        guard workspaceDriver == nil, !immediateScheduled, !inFrame, isRunning else { return }
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

    /// The display link already acquired a bounded drawable, so there is no pool wait
    /// to avoid with the legacy three-pending-presentation throttle.
    func presentDrawable(_ id: ObjectIdentifier, outputAt: Double?, present: @escaping () -> Void) {
        runContentPresentations([id: Presentation(outputAt: outputAt, present: present)], throttle: false)
    }

    /// Runs `step` once per frame, after terminal updates and before presentation, with
    /// the time the frame will be shown. Returning false ends the animation. A window that
    /// cannot animate finishes it at once by passing `.infinity`.
    func animate(_ id: ObjectIdentifier, surface: ObjectIdentifier? = nil, step: @escaping (Double) -> Bool) {
        animations[id] = Animation(surface: surface, step: step)
        activeUntil = max(activeUntil, now() + 0.05)
        if let surface, let driver = drawableDrivers[surface], canAnimate { driver() }
        else { wake() }
    }

    private func runAnimations(at time: Double, surface: ObjectIdentifier? = nil) {
        guard !animations.isEmpty else { return }
        for (id, animation) in animations {
            // A drawable advances only its own motion. Native/fallback animations use
            // the window clock; shutdown settles every animation without another frame.
            let belongs = surface.map { animation.surface == $0 } ??
                (animation.surface.map { drawableDrivers[$0] == nil } ?? true)
            guard belongs || !time.isFinite else { continue }
            if !animation.step(time) { animations.removeValue(forKey: id) }
        }
        if !animations.isEmpty { activeUntil = max(activeUntil, now() + 0.05) }
    }

    /// Called when a surface's tagged frame was shown (`presentedTime`, host time; 0 if discarded).
    func framePresented(tag: UInt64, presentedTime: Double) {
        guard let frame = taggedFrames.removeValue(forKey: tag) else { return }
        presentation.recordFrame(frame.surface, presentedAt: presentedTime, changed: frame.changed, inputs: frame.inputs,
                                 outputAt: frame.outputAt, submittedAt: frame.submittedAt, scroll: frame.scroll)
    }

    /// After a surface encoded the frame tagged `tag`: whether it differed from the previous
    /// frame, and for a scrolling surface the input and drawn positions in lines.
    func frameDrawn(tag: UInt64, changed: Bool, scroll: (input: Double, drawn: Double)?) {
        taggedFrames[tag]?.changed = changed
        taggedFrames[tag]?.scroll = scroll
        frameDrawnObserver?(tag, changed, scroll)
    }

    /// Benchmark hook: every drawn frame's tag, change flag and scroll positions.
    var frameDrawnObserver: ((UInt64, Bool, (input: Double, drawn: Double)?) -> Void)?

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
            if item.outputAt != nil, let waiting = pendingInputs.removeValue(forKey: id) { inputs = waiting }
            let time = now()
            taggedFrames[tag] = TaggedFrame(surface: id, inputs: inputs, outputAt: item.outputAt, submittedAt: time)
            presentationTag = tag
            item.present()
            presentationTag = 0
        }
        if taggedFrames.count > 512 {
            for key in taggedFrames.keys.sorted().prefix(taggedFrames.count - 256) { taggedFrames.removeValue(forKey: key) }
        }
    }

    private func wake() {
        guard canAnimate else { scheduleFallback(); return }
        if let workspaceDriver {
            if !isRunning { timing.pause() }
            isRunning = true; workspaceDriver(); return
        }
        guard let clock else { scheduleFallback(); return }
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

    private func drainDrawableUpdates() {
        let batches = drawableUpdates
        drawableUpdates.removeAll(keepingCapacity: true)
        for batch in batches.values { batch.forEach { $0() } }
    }

    private func drainWithoutAnimation() {
        drainDrawableUpdates()
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
    private func frame(immediate: Bool = false, targetTimestamp: Double? = nil) {
        guard canAnimate else { drainWithoutAnimation(); return }
        let start = now()
        inFrame = true
        defer { inFrame = false }
        lastFrameStart = start
        os_signpost(.begin, log: Self.log, name: immediate ? "Window.ImmediateFrame" : "Window.Frame")
        drainUpdates()
        if !immediate { runAnimations(at: targetTimestamp ?? clock?.targetTimestamp ?? start + 1 / Double(targetRate)) }
        let presentations = pendingPresentations
        pendingPresentations.removeAll(keepingCapacity: true)
        // Unchanged surfaces are not presented again. Repeating a frame after input keeps
        // ProMotion at its top rate, but each repeat queues a drawable ahead of the next
        // real one: measured here it added about 9 ms from key press to display and
        // blocked the main thread in nextDrawable.
        runContentPresentations(presentations)
        // AppKit services native dirty views in its run loop. Forcing a whole-window
        // pass here also enters MTKView outside its supplied-drawable callback.
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
        Key presses without output from the focused terminal: \(presentation.unmatchedInputs)
        Interval between new terminal frames on screen: \(cadence)
        Frames shown: \(presentation.presentedFrames) · identical to the previous: \(presentation.unchangedFrames)

        Both use the time each frame reached the display (MTLDrawable.presentedTime). Key latency starts at the event's timestamp and excludes keyboard and panel hardware. Frame intervals reflect how often content changed, so they are long while typing and 8.3 ms during smooth scrolling at 120 Hz. Idle windows pause their clock.
        """
    }

    var gpuSamples: [ObjectIdentifier: (name: String, count: UInt64)] {
        surfaces.compactMapValues { $0.sample() }
    }

    var gpuChangedSamples: [ObjectIdentifier: UInt64] { surfaces.compactMapValues { $0.changedCount?() } }

    func invalidate() {
        clock?.invalidate(); clock = nil; workspaceDriver = nil; isRunning = false
        drawableDrivers.removeAll(); drainDrawableUpdates()
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
final class NativeDisplayClock: FrameClock {
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
