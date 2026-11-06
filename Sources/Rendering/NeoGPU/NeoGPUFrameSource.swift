import AppKit
import QuartzCore

/// A wake made while encoding a frame must survive that frame's idle decision.
/// Shared by all NeoGPU surfaces; it does not poll when no work remains.
struct NeoGPUFrameDemand {
    private(set) var requested = false
    mutating func wake() { requested = true }
    mutating func beginFrame() { requested = false }
    mutating func endFrame(usedDrawable: Bool) -> Bool { usedDrawable || requested }
}

enum NeoGPUFrameLatency {
    // Controlled release experiment; unset retains Apple's default. Only the
    // documented 1- and 2-frame leads are accepted, with no rate/timer changes.
    static func requested(_ value: String?) -> Float? {
        guard let value, let frames = Float(value), frames == 1 || frames == 2 else { return nil }
        return frames
    }
}

/// Supplies bounded drawables at the display deadline. AppKit input/state is
/// latched on the main actor immediately before the owner's GPU encoding.
@available(macOS 14, *)
@MainActor
final class NeoGPUFrameSource: NSObject, CAMetalDisplayLinkDelegate, FrameClock {
    private var link: CAMetalDisplayLink?
    private var demand = NeoGPUFrameDemand()
    private(set) var targetTimestamp: Double?
    private let draw: (CAMetalDrawable) -> Bool
    /// Value read back from the link after configuration, for benchmark reports.
    static private(set) var effectiveFrameLatency: Float?

    init(layer: CAMetalLayer, rate: Int, draw: @escaping (CAMetalDrawable) -> Bool) {
        self.draw = draw
        super.init()
        link = CAMetalDisplayLink(metalLayer: layer)
        link?.delegate = self
        if let latency = NeoGPUFrameLatency.requested(ProcessInfo.processInfo.environment["NEOLINK_FRAME_LATENCY"]) {
            link?.preferredFrameLatency = latency
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
        Self.effectiveFrameLatency = link?.preferredFrameLatency
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        MainActor.assumeIsolated {
            targetTimestamp = update.targetPresentationTimestamp
            demand.beginFrame()
            let used = draw(update.drawable)
            if !demand.endFrame(usedDrawable: used) { link.isPaused = true }
        }
    }
    func start() { demand.wake(); link?.isPaused = false }
    func stop() { link?.isPaused = true }
    func invalidate() { let previous = link; link = nil; previous?.delegate = nil; previous?.invalidate() }
    deinit { link?.invalidate() }
}

/// How the shared workspace obtains and presents drawables.
enum NeoGPUPresentation {
    /// `CAMetalDisplayLink` supplies drawables ahead of a target presentation time it chooses.
    case displayLink
    /// The window's `CADisplayLink` ticks at each refresh; the workspace takes `nextDrawable()` and presents as
    /// soon as it is encoded, with at most `NeoGPUDirectFrameSource.maximumQueued` drawables waiting to be shown.
    case direct

    static var current: NeoGPUPresentation {
        ProcessInfo.processInfo.environment["NEOLINK_PRESENTATION"] == "link" ? .displayLink : .direct
    }
}

/// One display clock for the workspace that presents as soon as a frame is encoded, instead of at a target
/// time several refreshes ahead. Pacing comes from the refresh-rate display link; latency is bounded by
/// never letting more than `maximumQueued` drawables wait for the display, so a slow frame cannot leave a
/// standing queue (and its extra latency) behind it.
@available(macOS 14, *)
@MainActor
final class NeoGPUDirectFrameSource: NSObject, FrameClock {
    private var link: CADisplayLink?
    private weak var layer: CAMetalLayer?
    private var demand = NeoGPUFrameDemand()
    private(set) var targetTimestamp: Double?
    private let draw: (CAMetalDrawable) -> (keepRunning: Bool, presented: Bool)
    /// Drawables handed to the display and not yet shown. Decremented on Core Animation's presentation callback
    /// thread directly, so a busy main thread cannot make the queue look fuller than it is.
    private let queue = QueuedDrawables()
    private var lastAcquired = 0.0
    static let maximumQueued = 2
    /// Refreshes skipped because enough frames were already waiting (diagnostic).
    private(set) var skippedForQueue = 0

    init(layer: CAMetalLayer, view: NSView, rate: Int, draw: @escaping (CAMetalDrawable) -> (keepRunning: Bool, presented: Bool)) {
        self.layer = layer
        self.draw = draw
        super.init()
        let target = DirectDisplayTarget()
        let link = view.displayLink(target: target, selector: #selector(DirectDisplayTarget.step(_:)))
        target.owner = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        targetTimestamp = link.targetTimestamp
        demand.beginFrame()
        let now = CACurrentMediaTime()
        // A presentation callback that never arrives must not stall the workspace forever.
        let period = link.targetTimestamp - link.timestamp
        if queue.count(at: now, grace: period / 2) >= Self.maximumQueued, now - lastAcquired > 0.25 { queue.reset() }
        // A frame counts as waiting until it is shown, or until half a refresh after the refresh it was made for:
        // its presentation callback can trail the very refresh at which this tick runs.
        guard queue.count(at: now, grace: period / 2) < Self.maximumQueued, let layer, let drawable = layer.nextDrawable() else {
            skippedForQueue += 1
            return   // stay running: the waiting frames will be shown and the next refresh draws
        }
        lastAcquired = now
        let queue = self.queue
        let id = queue.add(target: link.targetTimestamp)
        drawable.addPresentedHandler { _ in queue.remove(id) }
        let result = draw(drawable)
        if !result.presented { queue.remove(id) }
        if !demand.endFrame(usedDrawable: result.keepRunning) { link.isPaused = true }
    }

    func start() { demand.wake(); link?.isPaused = false }
    func stop() { link?.isPaused = true }
    func invalidate() { link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}

/// The display link retains its target; keep the frame source out of that cycle.
@available(macOS 14, *)
@MainActor
private final class DirectDisplayTarget: NSObject {
    weak var owner: NeoGPUDirectFrameSource?
    @objc func step(_ link: CADisplayLink) { owner?.tick(link) }
}

final class QueuedDrawables: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: UInt64, target: Double)] = []
    private var next: UInt64 = 0
    func count(at now: Double, grace: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.target + grace > now }.count
    }
    func add(target: Double) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        next &+= 1
        entries.append((next, target))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        return next
    }
    func remove(_ id: UInt64) { lock.lock(); entries.removeAll { $0.id == id }; lock.unlock() }
    func reset() { lock.lock(); entries.removeAll(); lock.unlock() }
}
