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

/// Supplies bounded drawables at the display deadline. AppKit input/state is
/// latched on the main actor immediately before the owner's GPU encoding.
@available(macOS 14, *)
@MainActor
final class NeoGPUFrameSource: NSObject, CAMetalDisplayLinkDelegate, FrameClock {
    private var link: CAMetalDisplayLink?
    private var demand = NeoGPUFrameDemand()
    private(set) var targetTimestamp: Double?
    private let draw: (CAMetalDrawable) -> Bool

    init(layer: CAMetalLayer, rate: Int, draw: @escaping (CAMetalDrawable) -> Bool) {
        self.draw = draw
        super.init()
        link = CAMetalDisplayLink(metalLayer: layer)
        link?.delegate = self
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
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
