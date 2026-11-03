import AppKit
import QuartzCore

@available(macOS 14, *)
@MainActor
final class MetalDrawableClock: NSObject, CAMetalDisplayLinkDelegate, FrameClock {
    private var link: CAMetalDisplayLink?
    private(set) var targetTimestamp: Double?
    private let draw: (CAMetalDrawable) -> Void
    init(layer: CAMetalLayer, rate: Int, draw: @escaping (CAMetalDrawable) -> Void) {
        self.draw = draw
        super.init()
        link = CAMetalDisplayLink(metalLayer: layer)
        link?.delegate = self
        // Keep the system's default two-frame render budget, as GPUI does. A one-frame
        // budget made the terminal miss refreshes when it shared this drawable callback.
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }
    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // Installed on the main run loop; keep AppKit and scene access on that actor.
        MainActor.assumeIsolated {
            targetTimestamp = update.targetPresentationTimestamp
            draw(update.drawable)
        }
    }
    func start() { link?.isPaused = false }
    func stop() { link?.isPaused = true }
    func invalidate() { let previous = link; link = nil; previous?.delegate = nil; previous?.invalidate() }
    deinit { link?.invalidate() }
}
