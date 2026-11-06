import AppKit
import Combine
import QuartzCore
import SwiftTerm
import Metal

/// One setting covers shells, SSH, agent terminals, and the embedded Neovim surface.
@MainActor
final class TerminalRenderingPreferences: ObservableObject {
    static let shared = TerminalRenderingPreferences()
    @Published private(set) var useGPU: Bool
    @Published private(set) var continuousRefresh: Bool
    private let defaults: UserDefaults
    private static let key = "NeoLink.useGPUTextRendering"
    private static let refreshKey = "NeoLink.continuousGPURefresh"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useGPU = defaults.object(forKey: Self.key) as? Bool ?? true
        continuousRefresh = defaults.object(forKey: Self.refreshKey) as? Bool ?? true
    }

    func setUseGPU(_ enabled: Bool) {
        guard enabled != useGPU else { return }
        defaults.set(enabled, forKey: Self.key)
        useGPU = enabled
    }

    func setContinuousRefresh(_ enabled: Bool) {
        guard enabled != continuousRefresh else { return }
        defaults.set(enabled, forKey: Self.refreshKey)
        continuousRefresh = enabled
    }
}

/// Configures SwiftTerm's glyph-atlas/Metal-quad renderer after its view has a window.
/// SwiftTerm owns dirty rows, drawable lifetimes and recovery. The window owns
/// frame pacing, shared with native controls and all other visible surfaces.
@MainActor
final class TerminalRendering: NeoGPUClient {
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
    private var editorSelections: [UInt64: UInt64] = [:]
    private func recordEditorSelection(_ tag: UInt64) {
        guard tag != 0, let editor = view as? CodeTerminalView, let session = editor.session else { return }
        if editorSelections.count > 64 { editorSelections.removeAll(keepingCapacity: true) }
        editorSelections[tag] = session.parsedSelection
    }
    private(set) var drawableCounters: [String: Int] = [:]
    private weak var workspaceGPU: NeoGPUWorkspace?
    private var workspaceObserver: NSObjectProtocol?
    private var hostTexture: MTLTexture?
    private var hostScene: NeoGPUScene?
    private var hostTextureReady = false
    private var hostBufferSelection: UInt64?
    private var disablingGPU = false

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
        workspaceGPU?.unregister(self)
        if let workspaceObserver { NotificationCenter.default.removeObserver(workspaceObserver) }
        workspaceObserver = NotificationCenter.default.addObserver(forName: .neoGPUWorkspaceReady, object: view.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.prepareDrawableClock() }
        }
        let id = ObjectIdentifier(view)
        let kind = view is CodeTerminalView ? "editor" : "shell"
        frames?.unregister(id)
        frames = WindowFrameScheduler.forWindow(view.window)
        drawableClock?.invalidate(); drawableClock = nil; drawableLayer = nil
        pendingDraw = nil; pendingOutput = nil
        frames?.register(id) { [weak view] in
            guard let view, Self.isVisible(view), view.isUsingMetalRenderer else { return nil }
            return (view is CodeTerminalView ? "Editor" : "Terminal", view.metalRendererStatus.presentedFrameCount)
        }
        view.metalFramePresented = { [weak self] tag, presentedTime in
            MainActor.assumeIsolated {
                // The display's timestamp; 0 when the system did not report one.
                let time = presentedTime > 0 ? presentedTime : CACurrentMediaTime()
                PhaseTrace.mark(kind + ".firstFramePresented", at: time)
                if let self, let token = self.editorSelections.removeValue(forKey: tag), let editor = self.view as? CodeTerminalView {
                    editor.session?.selectionPresented(token, at: presentedTime)
                }
                // The editor draws once while still hidden; its first frame a user sees comes after it is shown.
                if let shown = PhaseTrace.moments[kind + ".shown"], time > shown { PhaseTrace.mark(kind + ".firstFrameAfterShown", at: time) }
            }
            guard tag != 0 else { return }
            MainActor.assumeIsolated { self?.frames?.framePresented(tag: tag, presentedTime: presentedTime) }
        }
        view.displayUpdateScheduler = { [weak self] update in
            Self.onMain {
                guard let self, let view = self.view, let frames = self.frames,
                      Self.isVisible(view) || (view as? CodeTerminalView)?.session?.requestedPath != nil else {
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
                    let draw = { [weak self, weak view, weak frames] in
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
                            self?.recordEditorSelection(tag)
                            frames.frameDrawn(tag: tag, changed: view.metalLastFrameChanged, scroll: view.scrollTraceSample())
                        }
                    }
                    if self.prepareDrawableClock() {
                        self.drawableCounters["requests", default: 0] += 1
                        self.pendingDraw = draw
                        self.pendingOutput = self.pendingOutput ?? output
                        self.drawableClock?.start()
                        self.workspaceGPU?.wake()
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
        guard !disablingGPU, #available(macOS 14, *), let view, view.isUsingMetalRenderer,
              let layer = view.metalDisplayLayer else { return false }
        if let workspace = NeoGPUWorkspace.forWindow(view.window) {
            if workspaceGPU !== workspace {
                drawableClock?.invalidate(); drawableClock = nil; drawableLayer = nil
                workspaceGPU = workspace; workspace.register(self)
            }
            frames?.setDrawableDriver(ObjectIdentifier(view), wake: { [weak workspace] in workspace?.wake() })
            return true
        }
        let rate = WindowFrameScheduler.rate(for: view.window?.screen?.maximumFramesPerSecond ?? 60)
        if drawableLayer !== layer || drawableRate != rate {
            drawableClock?.invalidate()
            drawableLayer = layer
            drawableRate = rate
            view.metalUsesExternalDrawables = true
            drawableClock = NeoGPUFrameSource(layer: layer, rate: rate) { [weak self] drawable in
                self?.drawableCounters["callbacks", default: 0] += 1
                guard let self, let view = self.view, Self.isVisible(view),
                      view.metalDisplayLayer === self.drawableLayer, let frames = self.frames else {
                    self?.drawableClock?.stop()
                    return false
                }
                // Consume all parsed state for this surface immediately before drawing.
                // The update may schedule/replace pendingDraw with the newest dirty rows.
                let id = ObjectIdentifier(view)
                view.process?.servicePendingOutput()
                frames.prepareDrawable(id, at: self.drawableClock?.targetTimestamp)
                guard let draw = self.pendingDraw else {
                    return frames.hasDrawableAnimation(id)
                }
                self.pendingDraw = nil
                let output = self.pendingOutput; self.pendingOutput = nil
                view.metalExternalDrawable = drawable
                frames.presentDrawable(ObjectIdentifier(view), outputAt: output, present: draw)
                self.drawableCounters[view.metalNextFrameTag == 0 ? "submitted" : "refused", default: 0] += 1
                view.metalExternalDrawable = nil
                return true
                // Stay warm until an update arrives with no pending draw. Returning
                // that unused drawable pauses the link without queuing a repeat.
            }
        }
        if drawableClock != nil {
            frames?.setDrawableDriver(ObjectIdentifier(view), wake: { [weak self] in self?.drawableClock?.start() })
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
            disablingGPU = true
            defer { disablingGPU = false }
            workspaceGPU?.unregister(self)
            frames?.setDrawableDriver(ObjectIdentifier(view), wake: nil)
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
            _ = prepareDrawableClock()
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
        return "\(status)\nPresentation: \(workspaceGPU == nil ? "independent surface" : "NeoGPU workspace scene")\nPresented GPU frames: \(view.metalRendererStatus.presentedFrameCount)\nDisplay maximum refresh rate: \(refresh) Hz\n\n\(frames?.summary ?? "Native on-demand drawing")"
    }

    var gpuInputView: NSView? { view }
    func gpuLatchOutput() {
        guard let view else { return }
        // A pending selection must parse its post-redraw marker while hidden.
        // Other hidden sessions retain ordinary queue delivery and do no extra
        // work on the visible workspace's deadline.
        guard Self.isVisible(view) || (view as? CodeTerminalView)?.session?.requestedPath != nil else { return }
        view.process?.servicePendingOutput()
    }
    func gpuReleaseHiddenResources() {
        hostTexture = nil; hostScene = nil; hostTextureReady = false; hostBufferSelection = nil
    }
    func gpuSetHosted(_ hosted: Bool) {
        guard let view else { return }
        view.metalUsesExternalDrawables = hosted
        if !hosted {
            workspaceGPU = nil; hostTexture = nil; hostScene = nil; hostTextureReady = false; hostBufferSelection = nil
            view.metalHostTexture = nil; view.metalHostCommandBuffer = nil; view.metalHostFrameEncoded = nil
            view.metalDisplayLayer?.opacity = 1
            if !disablingGPU {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.prepareDrawableClock()
                    self?.view?.needsDisplay = true
                }
            }
        }
    }

    func gpuPrepare(time: Double, command: MTLCommandBuffer) -> NeoGPUNode? {
        guard let view, let frames, let workspaceGPU, view.isUsingMetalRenderer else { return nil }
        let id = ObjectIdentifier(view), scale = view.window?.backingScaleFactor ?? 2
        let prepareBegan = CACurrentMediaTime()
        frames.prepareDrawable(id, at: time)
        // Preparation drains PTY updates; correlate the buffer actually encoded,
        // including a marker parsed during this very display callback.
        let traceToken = (view as? CodeTerminalView)?.session?.parsedSelection ?? SelectionTrace.current
        SelectionTrace.mark(traceToken, "frame.prepare", at: prepareBegan,
                            fields: ["targetPresentationTime": time, "leadSeconds": time - prepareBegan])
        let width = max(1, Int((view.bounds.width * scale).rounded()))
        let height = max(1, Int((view.bounds.height * scale).rounded()))
        var fresh = false
        if hostTexture?.width != width || hostTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = workspaceGPU.device.makeTexture(descriptor: descriptor),
                  let scene = try? NeoGPUScene(device: workspaceGPU.device, revision: 0, quads: [
                    .init(bounds: .init(0, 0, Float(width), Float(height)), color: .zero, texture: texture)]) else { workspaceGPU.fail(); return nil }
            hostTexture = texture; hostScene = scene; hostTextureReady = false; fresh = true
        }
        var encoded: UInt64 = 0
        let bufferSelection = (view as? CodeTerminalView)?.session?.parsedSelection
        // A marker serviced by this deadline can unhide the editor before a
        // previously queued native update has run. A retained texture from a
        // different acknowledged selection must be re-encoded, never exposed.
        if pendingDraw != nil || fresh || !hostTextureReady || bufferSelection != hostBufferSelection {
            let output = pendingOutput; pendingOutput = nil
            let draw = pendingDraw ?? { [weak self, weak view, weak frames] in
                guard let view, let frames else { return }
                let tag = frames.presentationTag
                if view.metalNextFrameTag != 0 { frames.mergeTag(view.metalNextFrameTag, into: tag) }
                view.metalNextFrameTag = tag
                view.drawMetalFrameNow()
                if view.metalNextFrameTag == 0 {
                    self?.recordEditorSelection(tag)
                    frames.frameDrawn(tag: tag, changed: view.metalLastFrameChanged, scroll: view.scrollTraceSample())
                }
            }
            pendingDraw = nil
            view.metalHostTexture = hostTexture; view.metalHostCommandBuffer = command
            view.metalHostFrameEncoded = { encoded = $0 }
            SelectionTrace.mark(traceToken, "frame.encode.begin")
            frames.presentDrawable(id, outputAt: output, present: draw)
            SelectionTrace.mark(traceToken, "frame.encode.end")
            if SelectionTrace.enabled, encoded != 0 {
                command.addScheduledHandler { _ in SelectionTrace.mark(traceToken, "gpu.scheduled") }
                command.addCompletedHandler { _ in SelectionTrace.mark(traceToken, "gpu.completed") }
            }
            view.metalHostTexture = nil; view.metalHostCommandBuffer = nil; view.metalHostFrameEncoded = nil
            if encoded == 0 { pendingDraw = draw }
            else { hostTextureReady = true; hostBufferSelection = bufferSelection }
        }
        guard hostTextureReady, let scene = hostScene else { return nil }
        return NeoGPUNode(scene: scene, needsAnotherFrame: pendingDraw != nil || frames.hasDrawableAnimation(id), traceSelection: encoded == 0 ? 0 : traceToken, presented: { [weak view] time in
            guard let view else { return }
            if !(view is CodeTerminalView) { SelectionTrace.mark(traceToken, "shell.presented", at: time) }
            view.metalDisplayLayer?.opacity = 0
            view.metalHostFramePresented(tag: encoded, time: time)
        })
    }

    deinit { if let workspaceObserver { NotificationCenter.default.removeObserver(workspaceObserver) } }
}
