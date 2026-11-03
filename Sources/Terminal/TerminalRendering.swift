import AppKit
import Combine
import QuartzCore
import SwiftTerm

/// One setting covers shells, SSH, agent terminals, and the embedded Neovim surface.
@MainActor
final class TerminalRenderingPreferences: ObservableObject {
    static let shared = TerminalRenderingPreferences()
    @Published private(set) var useGPU: Bool
    private let defaults: UserDefaults
    private static let key = "NeoLink.useGPUTextRendering"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useGPU = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func setUseGPU(_ enabled: Bool) {
        guard enabled != useGPU else { return }
        defaults.set(enabled, forKey: Self.key)
        useGPU = enabled
    }
}

/// Configures SwiftTerm's glyph-atlas/Metal-quad renderer after its view has a window.
/// SwiftTerm owns dirty rows, drawable lifetimes and recovery. The window owns
/// frame pacing, shared with native controls and all other visible surfaces.
@MainActor
final class TerminalRendering {
    private weak var view: InteractiveTerminalView?
    private let preferences: TerminalRenderingPreferences
    private var observation: AnyCancellable?
    private var attemptedGPU = false
    private weak var frames: WindowFrameScheduler?
    private(set) var failure: String?
    private var drawableClock: FrameClock?
    private weak var drawableLayer: CAMetalLayer?
    private var drawableRate = 0
    private var pendingDraw: (() -> Void)?
    private var pendingOutput: Double?
    private(set) var drawableCounters: [String: Int] = [:]

    init(view: InteractiveTerminalView, preferences: TerminalRenderingPreferences? = nil) {
        self.view = view
        self.preferences = preferences ?? .shared
        observation = self.preferences.$useGPU.dropFirst().sink { [weak self] enabled in
            // @Published emits before the stored value changes; use the emitted value.
            self?.apply(enabled: enabled, retry: true)
        }
    }

    /// When program output first arrived since the last frame; that frame answers pending key presses.
    private var outputSinceLastFrame: Double?
    func noteOutput() { if outputSinceLastFrame == nil { outputSinceLastFrame = CACurrentMediaTime() } }

    func attachToWindow() {
        guard let view else { return }
        let id = ObjectIdentifier(view)
        let kind = view is CodeTerminalView ? "editor" : "shell"
        frames?.unregister(id)
        frames = WindowFrameScheduler.forWindow(view.window)
        frames?.register(id) { [weak view] in
            guard let view, Self.isVisible(view), view.isUsingMetalRenderer else { return nil }
            return (view is CodeTerminalView ? "Editor" : "Terminal", view.metalRendererStatus.presentedFrameCount)
        }
        view.metalFramePresented = { [weak self] tag, presentedTime in
            MainActor.assumeIsolated {
                // The display's timestamp; 0 when the system did not report one.
                let time = presentedTime > 0 ? presentedTime : CACurrentMediaTime()
                PhaseTrace.mark(kind + ".firstFramePresented", at: time)
                // The editor draws once while still hidden; its first frame a user sees comes after it is shown.
                if let shown = PhaseTrace.moments[kind + ".shown"], time > shown { PhaseTrace.mark(kind + ".firstFrameAfterShown", at: time) }
            }
            guard tag != 0 else { return }
            MainActor.assumeIsolated { self?.frames?.framePresented(tag: tag, presentedTime: presentedTime) }
        }
        view.displayUpdateScheduler = { [weak self] update in
            Self.onMain {
                guard let self, let view = self.view, Self.isVisible(view), let frames = self.frames else {
                    DispatchQueue.main.async { update() }
                    return
                }
                frames.enqueue(from: ObjectIdentifier(view), update)
            }
        }
        view.metalFrameScheduler = { [weak self] present in
            Self.onMain {
                guard let self, let view = self.view, Self.isVisible(view) else { return }
                if let frames = self.frames {
                    let output = self.outputSinceLastFrame
                    self.outputSinceLastFrame = nil
                    let draw = { [weak view, weak frames] in
                        guard let view, let frames else { return }
                        let tag = frames.presentationTag
                        if tag != 0 {
                            if view.metalNextFrameTag != 0 { frames.mergeTag(view.metalNextFrameTag, into: tag) }
                            view.metalNextFrameTag = tag
                        }
                        // Encode input echoes promptly, but let the display present every
                        // surface at a refresh boundary, including direct/full-screen mode.
                        view.metalPresentsImmediately = false
                        present()
                        // The renderer consumed the tag only if it submitted the frame.
                        if tag != 0, view.metalNextFrameTag == 0 {
                            frames.frameDrawn(tag: tag, changed: view.metalLastFrameChanged, scroll: view.scrollTraceSample())
                        }
                    }
                    if self.prepareDrawableClock() {
                        self.drawableCounters["requests", default: 0] += 1
                        self.pendingDraw = draw
                        self.pendingOutput = self.pendingOutput ?? output
                        self.drawableClock?.start()
                    } else {
                        frames.requestPresentation(ObjectIdentifier(view), outputAt: output, present: draw)
                    }
                } else {
                    DispatchQueue.main.async { [weak view] in
                        if let view, Self.isVisible(view) { present() }
                    }
                }
            }
        }
        apply(enabled: preferences.useGPU, retry: false)
    }

    private func prepareDrawableClock() -> Bool {
        guard #available(macOS 14, *), let view, view.isUsingMetalRenderer,
              let layer = view.metalDisplayLayer else { return false }
        let rate = WindowFrameScheduler.rate(for: view.window?.screen?.maximumFramesPerSecond ?? 60)
        if drawableLayer !== layer || drawableRate != rate {
            drawableClock?.invalidate()
            drawableLayer = layer
            drawableRate = rate
            view.metalUsesExternalDrawables = true
            drawableClock = MetalDrawableClock(layer: layer, rate: rate) { [weak self] drawable in
                self?.drawableCounters["callbacks", default: 0] += 1
                guard let self, let view = self.view, Self.isVisible(view),
                      view.metalDisplayLayer === self.drawableLayer, let draw = self.pendingDraw, let frames = self.frames else {
                    self?.drawableClock?.stop()
                    return
                }
                self.pendingDraw = nil
                let output = self.pendingOutput; self.pendingOutput = nil
                view.metalExternalDrawable = drawable
                frames.presentDrawable(ObjectIdentifier(view), outputAt: output, present: draw)
                self.drawableCounters[view.metalNextFrameTag == 0 ? "submitted" : "refused", default: 0] += 1
                view.metalExternalDrawable = nil
                // Stay warm until an update arrives with no pending draw. Returning
                // that unused drawable pauses the link without queuing a repeat.
            }
        }
        return drawableClock != nil
    }

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) }
        else { DispatchQueue.main.async { work() } }
    }

    private static func isVisible(_ view: InteractiveTerminalView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true && view.window?.isMiniaturized == false
    }

    private func apply(enabled: Bool, retry: Bool) {
        guard let view, view.window != nil else { return }
        if retry { attemptedGPU = false; failure = nil }
        if !enabled {
            drawableClock?.invalidate(); drawableClock = nil; drawableLayer = nil
            pendingDraw = nil; pendingOutput = nil
            view.metalUsesExternalDrawables = false; view.metalExternalDrawable = nil
            try? view.setUseMetal(false)
            attemptedGPU = false
            return
        }
        guard !attemptedGPU else { return }
        attemptedGPU = true
        // Keep unchanged row geometry cached for editing and ordinary terminal output.
        view.metalBufferingMode = .perRowPersistent
        do {
            try PhaseTrace.measure(view is CodeTerminalView ? "editor.metalSetup" : "shell.metalSetup") {
                try view.setUseMetal(true)
            }
        } catch {
            failure = String(describing: error)
            try? view.setUseMetal(false)
            NSLog("NeoLink: Metal text rendering unavailable; using CoreGraphics: %@", failure ?? "unknown error")
        }
    }

    var summary: String {
        guard let view else { return "No terminal is active." }
        let status: String
        switch view.metalRendererStatus.state {
        case .healthy: status = "Metal (GPU) — presenting frames"
        case .waitingForFirstFrame: status = "Metal (GPU) — waiting for its first frame"
        case .recovering: status = "Metal (GPU) — recovering"
        case .fellBackToCoreGraphics: status = "CoreGraphics — automatic GPU recovery fallback"
        case .disabled: status = failure.map { "CoreGraphics — \($0)" } ?? "CoreGraphics"
        }
        let refresh = view.window?.screen?.maximumFramesPerSecond ?? 60
        return "\(status)\nPresented GPU frames: \(view.metalRendererStatus.presentedFrameCount)\nDisplay maximum refresh rate: \(refresh) Hz\n\n\(frames?.summary ?? "Native on-demand drawing")"
    }
}
