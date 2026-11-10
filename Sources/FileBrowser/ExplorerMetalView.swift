import AppKit
@preconcurrency import CoreText
@preconcurrency import Metal
import QuartzCore

/// GPU row composition over the native table. The table remains the input/accessibility
/// surface; immutable row artwork is rasterized once off-thread, cached, and translated by
/// Metal while scrolling. Missing artwork or a GPU failure reveals the native table.
@MainActor
final class ExplorerMetalView: NSView, NeoGPUClient {
    struct Scene {
        let rows: [ExplorerRow]
        let active: URL?
        let selected: Int
        let hovered: Int?
    }
    private struct Artwork {
        let row: ExplorerRow
        let width: Int
        let scale: CGFloat
        let texture: MTLTexture
        var used: UInt64
    }
    private struct Composition {
        let rows: Range<Int>
        let revision: UInt64
        let scale: CGFloat
        let texture: MTLTexture
    }
    private var composition: Composition?
    private struct Highlights: Equatable {
        let selected: Int
        let hovered: Int?
        let active: URL?
    }
    private var highlightKey: Highlights?
    private var highlightedScene: NeoGPUScene?
    private var contentRevision: UInt64 = 1
    private var activeLookup: (revision: UInt64, url: URL?, index: Int?)?

    /// Discard row-indexed state before AppKit can reenter drawing during reloads.
    /// This does not evaluate the scene or schedule artwork against the old rows.
    func invalidateRowContent() {
        contentRevision &+= 1; sceneRevision &+= 1
        composition = nil; highlightedScene = nil; highlightKey = nil; activeLookup = nil
        dirty = true
    }

    /// Highlights change only a few row quads, never the retained text strip.
    func invalidateHighlights() { invalidateScene(contentChanged: false, highlightsChanged: true) }
    // Tests compare the cached GPU pass with the original per-row pass pixel for pixel.
    var usesCachedComposition = true
    private(set) var compositionBuilds = 0
    private(set) var compositionReuses = 0
    var recordsMotionSamples = false
    /// Opt-in benchmark timing; normal drawing installs no profiling completion.
    var frameProfile: ((_ cpu: Double, _ gpu: Double) -> Void)?
    private struct JobKey: Hashable { let id: URL; let width: Int; let scale: CGFloat; let generation: UInt64 }
    private struct Raster {
        let width: Int, height: Int
        let pixels: Data
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let gpu: NeoGPURenderer
    private let worker = DispatchQueue(label: "com.neolink.explorer.artwork", qos: .userInitiated)
    private var rasterViewport = 0..<0
    private var cache: [URL: Artwork] = [:]
    private var jobs: Set<JobKey> = []
    private let rasterEpoch = ExplorerRasterEpoch()
    private var artworkSize: (width: Int, scale: CGFloat)?
    private var generation: UInt64 = 0
    private var useCounter: UInt64 = 0
    private var displayDriver: FrameClock?
    private var legacyClock: FrameClock?
    private var activeUntil = 0.0
    private var dirty = true
    private let frameSlot = ExplorerFrameSlot()
    private var lastPosition = CGFloat.nan
    private var lastSceneRevision: UInt64 = 0
    private var sceneRevision: UInt64 = 1
    private var observer: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var scroll: NSScrollView?
    private weak var frames: WindowFrameScheduler?
    private weak var workspaceGPU: NeoGPUWorkspace?
    private var stoppingGPU = false
    var scene: (() -> Scene)?
    var coverageChanged: ((Bool) -> Void)?
    private(set) var isCoveringNativeRows = false
    private(set) var presentedFrames: UInt64 = 0
    private(set) var changedFrames: UInt64 = 0
    private(set) var presentedSceneRevision: UInt64 = 0
    private(set) var presentedSceneTime = 0.0
    var visualRevision: UInt64 { sceneRevision }
    private(set) var nativeFallbacks = 0
    private(set) var drawCallbacks = 0
    private(set) var lastDrawState = "waiting"
    private(set) var motionSamples: [(time: Double, y: Double, changed: Bool)] = []
    /// Opt-in tests only; normal rendering never copies pixels back to the CPU.
    var captureNextFrame: ((CGImage) -> Void)?
    private(set) var lastDrawnRange = 0..<0
    var cachedRowCount: Int { cache.count }
    private var artworkRefreshScheduled = false
    private var resizeRetryScheduled = false
    private var resizeRetries = 0
    static let cacheLimit = 512
    static var allowsFrameCapture = false

    nonisolated static func visibleRows(count: Int, y: CGFloat, height: CGFloat) -> Range<Int> {
        guard count > 0, y.isFinite, height.isFinite, height > 0 else { return 0..<0 }
        let first = min(count, max(0, Int(floor(y / 24))))
        return first..<min(count, max(first, Int(ceil((y + height) / 24))))
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { /* Metal owns the backing store. */ }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true; layer.framebufferOnly = !Self.allowsFrameCapture
        layer.displaySyncEnabled = true; layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        return layer
    }

    init?(scroll: NSScrollView) {
        guard let (device, pipeline, gpu) = Self.resources.snapshot(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.gpu = gpu; self.scroll = scroll
        super.init(frame: scroll.contentView.frame)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay; isHidden = true
        setAccessibilityElement(false)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateScene(contentChanged: false) }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    nonisolated private static let resources = Resources()
    nonisolated static func prepare() { resources.prepare() }
    private final class Resources: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (MTLDevice, MTLRenderPipelineState, NeoGPURenderer)?
        func snapshot() -> (MTLDevice, MTLRenderPipelineState, NeoGPURenderer)? {
            lock.lock(); defer { lock.unlock() }; return cached
        }
        func prepare() {
            lock.lock(); defer { lock.unlock() }
            guard cached == nil, let device = MTLCreateSystemDefaultDevice(),
                  let pipeline = ExplorerMetalView.pipeline(device: device) else { return }
            NeoGPUResources.shared.prepare(device: device)
            guard let gpu = NeoGPUResources.shared.renderer(device: device) else { return }
            cached = (device, pipeline, gpu)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
        displayDriver?.invalidate(); displayDriver = nil
        legacyClock?.invalidate(); legacyClock = nil
        frames?.unregister(ObjectIdentifier(self))
        frames = WindowFrameScheduler.forWindow(window)
        // Bounds, row metadata and hover already invalidate this surface. Typing in
        // another panel must not redraw an unchanged explorer for another second.
        frames?.register(ObjectIdentifier(self),
                         changedCount: { [weak self] in self?.changedFrames ?? 0 }) { [weak self] in
            guard let self, self.window?.isVisible == true else { return nil }
            let name = self.isCoveringNativeRows ? "Explorer" : "Explorer (native fallback: \(self.lastDrawState))"
            return (name, self.presentedFrames)
        }
        guard let window, let layer = layer as? CAMetalLayer else { uncover(); return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                     .neoGPUWorkspaceReady] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.didChangeScreenNotification || name == .neoGPUWorkspaceReady { self?.configureClock() }
                    self?.invalidateScene(contentChanged: false)
                }
            })
        }
        layer.contentsScale = window.backingScaleFactor
        layer.drawableSize = CGSize(width: max(1, ceil(bounds.width * window.backingScaleFactor)), height: max(1, ceil(bounds.height * window.backingScaleFactor)))
        configureClock()
        invalidateScene()
    }

    private func configureClock() {
        displayDriver?.invalidate(); displayDriver = nil
        legacyClock?.invalidate(); legacyClock = nil
        guard let window, let layer = layer as? CAMetalLayer else { return }
        if !Self.allowsFrameCapture, let workspace = NeoGPUWorkspace.forWindow(window) {
            workspaceGPU = workspace; workspace.register(self)
            return
        }
        if Self.allowsFrameCapture {
            // Explicit offscreen tests own drawable acquisition. A CAMetalDisplayLink
            // and nextDrawable must never be used together for the same layer.
        } else if #available(macOS 14, *) {
            displayDriver = NeoGPUFrameSource(layer: layer, rate: WindowFrameScheduler.rate(for: window.screen?.maximumFramesPerSecond ?? 60)) { [weak self] drawable in
                guard let self else { return false }
                self.draw(drawable: drawable)
                return self.lastDrawState == "submitted" || self.lastDrawState == "busy"
            }
        } else if #unavailable(macOS 14) {
            legacyClock = NativeDisplayClock(window: window) { [weak self] in
                guard let self, self.frameSlot.isAvailable, let drawable = (self.layer as? CAMetalLayer)?.nextDrawable() else { return }
                self.draw(drawable: drawable)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateScene()
    }

    func invalidateScene(contentChanged: Bool = true, highlightsChanged: Bool = false) {
        if contentChanged { invalidateRowContent() }
        else if highlightsChanged { sceneRevision &+= 1 }
        dirty = true
        // Keep ProMotion supplied during interaction, using display-link-provided drawables
        // rather than queuing redundant terminal frames ahead of the next real input.
        activeUntil = CACurrentMediaTime() + 1.0
        guard let scroll else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = scroll.backingAlignedRect(scroll.contentView.frame, options: .alignAllEdgesNearest)
        if let layer = layer as? CAMetalLayer {
            let scale = window?.backingScaleFactor ?? 2
            if layer.contentsScale != scale { layer.contentsScale = scale }
            let size = CGSize(width: max(1, ceil(bounds.width * scale)), height: max(1, ceil(bounds.height * scale)))
            if layer.drawableSize != size { layer.drawableSize = size; resizeRetries = 0 }
        }
        CATransaction.commit()
        guard let scene = scene?() else {
            uncover(); displayDriver?.stop(); legacyClock?.stop(); return
        }
        if !isCoveringNativeRows {
            guard artworkReady(scene: scene) else {
                uncover(); displayDriver?.stop(); legacyClock?.stop(); return
            }
        } else {
            _ = artworkReady(scene: scene)
        }
        // A hidden CAMetalLayer receives no display-link drawables. Warm its artwork
        // first, then expose the layer so its first frame can actually be delivered.
        isHidden = false
        displayDriver?.start(); legacyClock?.start(); workspaceGPU?.wake()
    }

    private func artworkReady(scene: Scene) -> Bool {
        guard let scroll, bounds.width > 0, bounds.height > 0 else { return false }
        let scale = window?.backingScaleFactor ?? 2, width = Int(ceil(bounds.width * scale))
        if artworkSize?.width != width || artworkSize?.scale != scale {
            generation &+= 1; rasterEpoch.set(generation)
            jobs.removeAll(); artworkRefreshScheduled = false; resizeRetryScheduled = false
            artworkSize = (width, scale)
        }
        let y = scroll.contentView.bounds.minY
        let visibleRows = Self.visibleRows(count: scene.rows.count, y: y, height: bounds.height)
        if reusableComposition(visible: visibleRows, width: width, scale: scale) != nil { return true }
        // A fast flick can leave the entire queued viewport behind. Cancel its
        // unfinished work before admitting newly visible rows; keep cached pixels.
        if !rasterViewport.isEmpty, !rasterViewport.overlaps(visibleRows), !jobs.isEmpty {
            generation &+= 1; rasterEpoch.set(generation)
            jobs.removeAll(); artworkRefreshScheduled = false
            resizeRetryScheduled = false; resizeRetries = 0
        }
        rasterViewport = visibleRows
        let first = visibleRows.lowerBound, end = visibleRows.upperBound
        let prefetchMargin = 48
        for index in first..<max(first, end) {
            let row = scene.rows[index]
            if let art = cache[row.id], art.row == row, art.width == width, art.scale == scale { continue }
            schedule(row, width: width, scale: scale)
        }
        // Warm nearest neighbors first, rather than spending the bounded queue
        // on the far edge of a 48-row prefetch range.
        for distance in 1...prefetchMargin {
            for index in [end + distance - 1, first - distance] where scene.rows.indices.contains(index) {
                let row = scene.rows[index]
                if let art = cache[row.id], art.row == row, art.width == width, art.scale == scale { continue }
                schedule(row, width: width, scale: scale)
            }
        }
        return (first..<max(first, end)).allSatisfy { index in
            let row = scene.rows[index]
            return cache[row.id].map { $0.row == row && $0.width == width && $0.scale == scale } ?? false
        }
    }

    func shutdown() {
        stoppingGPU = true
        workspaceGPU?.unregister(self)
        generation &+= 1; rasterEpoch.set(generation)
        artworkRefreshScheduled = false
        resizeRetryScheduled = false
        displayDriver?.invalidate(); displayDriver = nil
        legacyClock?.invalidate(); legacyClock = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
        frames?.unregister(ObjectIdentifier(self))
        uncover(); scene = nil; coverageChanged = nil
        cache.removeAll(); jobs.removeAll(); composition = nil
    }

    private func uncover() {
        if isCoveringNativeRows { nativeFallbacks += 1 }
        isCoveringNativeRows = false; coverageChanged?(false); isHidden = true
    }

    /// Offscreen pixel validation also works when the screen is locked. It deliberately
    /// says nothing about on-screen cadence; the release benchmark checks that separately.
    func drawOffscreenForTesting(beforeDraw: () -> Void = {}) {
        guard Self.allowsFrameCapture, frameSlot.isAvailable, let drawable = (layer as? CAMetalLayer)?.nextDrawable() else { return }
        beforeDraw()
        draw(drawable: drawable, allowOffscreen: true)
    }

    private func draw(drawable: CAMetalDrawable, allowOffscreen: Bool = false) {
        let profile = frameProfile
        let started = profile == nil ? 0 : CACurrentMediaTime()
        drawCallbacks += 1
        lastDrawState = "callback"
        guard let window, (allowOffscreen || (window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))),
              let scroll, let scene = scene?(), bounds.width > 0, bounds.height > 0 else {
            lastDrawState = "not visible"; displayDriver?.stop(); legacyClock?.stop(); return
        }
        guard frameSlot.isAvailable else { lastDrawState = "busy"; return }
        let scale = window.backingScaleFactor, width = Int(ceil(bounds.width * scale))
        guard drawable.texture.width == width, drawable.texture.height == Int(ceil(bounds.height * scale)) else {
            lastDrawState = "resizing"; uncover(); retryAfterResize(); return
        }
        let y = (scroll.contentView.bounds.minY * scale).rounded() / scale
        let visibleRows = Self.visibleRows(count: scene.rows.count, y: y, height: bounds.height)
        let visible = visibleRows
        let cachedComposition = reusableComposition(visible: visible, width: width, scale: scale)
        if cachedComposition == nil, !artworkReady(scene: scene) {
            // Missing artwork still reveals complete native rows; never cache blank text.
            lastDrawState = "artwork missing"; uncover(); displayDriver?.stop(); legacyClock?.stop(); return
        }
        if !dirty, CACurrentMediaTime() > activeUntil {
            lastDrawState = "idle"; displayDriver?.stop(); legacyClock?.stop(); return
        }
        let revision = sceneRevision
        let changed = y != lastPosition || revision != lastSceneRevision
        guard let command = queue.makeCommandBuffer() else { uncover(); return }
        let composed = cachedComposition ?? buildComposition(scene: scene, visible: visible, width: width, scale: scale, command: command)
        if let composed {
            if cachedComposition != nil { compositionReuses += 1 }
            let translation = SIMD2<Float>(0, Float((CGFloat(composed.rows.lowerBound) * 24 - y) * scale))
            do {
                try gpu.encode(displayScene(composed, scene: scene), into: drawable.texture, command: command, translation: translation,
                               clear: MTLClearColor(red: 20/255, green: 20/255, blue: 20/255, alpha: 1))
            } catch { composition = nil; uncover(); return }
        } else {
            guard let encoder = command.makeRenderCommandEncoder(descriptor: renderPass(drawable.texture)) else { uncover(); return }
            configure(encoder, texture: drawable.texture)
            encodeRows(scene: scene, visible: visible, y: y, width: width, scale: scale, encoder: encoder)
            encoder.endEncoding()
        }
        if let capture = captureNextFrame, !drawable.texture.isFramebufferOnly {
            captureNextFrame = nil
            capturePixels(drawable.texture, command: command, completion: capture)
        }
        lastDrawnRange = visible
        guard frameSlot.acquire() else { return }
        dirty = false; lastPosition = y; lastSceneRevision = sceneRevision
        resizeRetries = 0
        lastDrawState = "submitted"
        isHidden = false
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            DispatchQueue.main.async { [weak self] in
                guard let self, time > 0 else { return }
                self.presentedFrames &+= 1
                if revision > self.presentedSceneRevision {
                    self.presentedSceneRevision = revision; self.presentedSceneTime = time
                }
                if changed { self.changedFrames &+= 1 }
                if self.recordsMotionSamples {
                    self.motionSamples.append((time, Double(y), changed))
                    if self.motionSamples.count > 4000 { self.motionSamples.removeFirst(self.motionSamples.count - 4000) }
                }
                if !self.isHidden, !self.isCoveringNativeRows {
                    self.isCoveringNativeRows = true; self.coverageChanged?(true)
                }
            }
        }
        let slot = frameSlot
        if let profile {
            let cpu = CACurrentMediaTime() - started
            command.addCompletedHandler { buffer in
                guard buffer.gpuStartTime > 0, buffer.gpuEndTime >= buffer.gpuStartTime else { return }
                let gpu = buffer.gpuEndTime - buffer.gpuStartTime
                DispatchQueue.main.async { profile(cpu, gpu) }
            }
        }
        command.addCompletedHandler { [weak self] command in
            // Release on Metal's completion thread. Waiting for a main-run-loop hop can
            // make an already completed frame reject the next display-link update.
            slot.release()
            guard command.status == .error else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastDrawState = command.error?.localizedDescription ?? "completed"
                if command.status == .error { self.composition = nil; self.uncover(); self.displayDriver?.stop(); self.legacyClock?.stop() }
            }
        }
        command.present(drawable); command.commit()
    }

    private func retryAfterResize() {
        // A display-link drawable can reflect the previous layer size. Hiding the
        // rejected surface without another wake leaves it stuck on native rows,
        // especially after the first scrollbar changes the clip-view width.
        guard !resizeRetryScheduled, resizeRetries < 3 else { return }
        resizeRetryScheduled = true; resizeRetries += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self, self.generation == token else { return }
            self.resizeRetryScheduled = false
            guard self.window?.isVisible == true, self.window?.isMiniaturized == false else { return }
            self.invalidateScene(contentChanged: false)
        }
    }

    var gpuInputView: NSView? { scroll?.contentView }
    func gpuSetHosted(_ hosted: Bool) {
        if hosted {
            displayDriver?.invalidate(); displayDriver = nil
            legacyClock?.invalidate(); legacyClock = nil
        } else {
            workspaceGPU = nil; layer?.opacity = 1
            if !stoppingGPU { configureClock(); invalidateScene() }
        }
    }

    func gpuPrepare(time: Double, command: MTLCommandBuffer) -> NeoGPUNode? {
        guard let window, let scroll, let scene = scene?(), bounds.width > 0, bounds.height > 0 else { return nil }
        let started = frameProfile == nil ? 0 : CACurrentMediaTime()
        let scale = window.backingScaleFactor, width = Int(ceil(bounds.width * scale))
        let y = (scroll.contentView.bounds.minY * scale).rounded() / scale
        let visible = Self.visibleRows(count: scene.rows.count, y: y, height: bounds.height)
        let cached = reusableComposition(visible: visible, width: width, scale: scale)
        guard cached != nil || artworkReady(scene: scene) else { uncover(); return nil }
        guard let composed = cached ?? buildComposition(scene: scene, visible: visible, width: width, scale: scale, command: command) else {
            uncover(); return nil
        }
        if cached != nil { compositionReuses += 1 }
        guard let display = try? displayScene(composed, scene: scene) else { uncover(); return nil }
        let revision = sceneRevision
        let changed = y != lastPosition || revision != lastSceneRevision
        dirty = false; lastPosition = y; lastSceneRevision = sceneRevision
        lastDrawnRange = visible; lastDrawState = "NeoGPU workspace"
        isHidden = false
        if let profile = frameProfile {
            let cpu = CACurrentMediaTime() - started
            command.addCompletedHandler { buffer in
                let gpu = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
                DispatchQueue.main.async { profile(cpu, gpu) }
            }
        }
        return NeoGPUNode(scene: display, translation: .init(0, Float((CGFloat(composed.rows.lowerBound) * 24 - y) * scale)),
                          needsAnotherFrame: CACurrentMediaTime() < activeUntil, presented: { [weak self] time in
            guard let self else { return }
            self.presentedFrames &+= 1
            if revision > self.presentedSceneRevision {
                self.presentedSceneRevision = revision; self.presentedSceneTime = time
            }
            if changed { self.changedFrames &+= 1 }
            if self.recordsMotionSamples {
                self.motionSamples.append((time, Double(y), changed))
                if self.motionSamples.count > 4000 { self.motionSamples.removeFirst(self.motionSamples.count - 4000) }
            }
            self.layer?.opacity = 0
            if !self.isCoveringNativeRows { self.isCoveringNativeRows = true; self.coverageChanged?(true) }
        }, acknowledged: { [weak self] time in
            // A later drawable carrying this pane showed this revision or a newer
            // one. That satisfies "the change became visible" only: no frame count,
            // no position sample and no native-row coverage, which belong to the
            // drawable that actually carried a given position.
            guard let self, revision > self.presentedSceneRevision else { return }
            self.presentedSceneRevision = revision; self.presentedSceneTime = time
        })
    }

    private func reusableComposition(visible: Range<Int>, width: Int, scale: CGFloat) -> Composition? {
        guard usesCachedComposition, let composition, composition.revision == contentRevision,
              composition.texture.width == width, composition.scale == scale,
              composition.rows.lowerBound <= visible.lowerBound,
              composition.rows.upperBound >= visible.upperBound else { return nil }
        return composition
    }

    private func renderPass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 20/255, green: 20/255, blue: 20/255, alpha: 1)
        return pass
    }

    private func configure(_ encoder: MTLRenderCommandEncoder, texture: MTLTexture) {
        encoder.setRenderPipelineState(pipeline)
        var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    }

    /// Composite nearby immutable rows on the GPU once. Scrolling then samples this
    /// native-resolution strip with one quad; CPU row iteration and bindings are reused.
    private func buildComposition(scene: Scene, visible: Range<Int>, width: Int, scale: CGFloat,
                                  command: MTLCommandBuffer) -> Composition? {
        guard usesCachedComposition, !visible.isEmpty else { return nil }
        let rowHeight = Int((24 * scale).rounded())
        // Additional GPU storage is bounded independently of the row artwork cache.
        let maxRows = min(16384 / max(1, rowHeight), (16 * 1024 * 1024) / max(1, width * rowHeight * 4))
        guard visible.count <= maxRows else { composition = nil; return nil }
        var first = visible.lowerBound, end = visible.upperBound
        let margin = min(24, (maxRows - visible.count) / 2)
        func ready(_ index: Int) -> Bool {
            let row = scene.rows[index]
            return cache[row.id].map { $0.row == row && $0.width == width && $0.scale == scale } ?? false
        }
        while first > max(0, visible.lowerBound - margin), ready(first - 1) { first -= 1 }
        while end < min(scene.rows.count, visible.upperBound + margin), ready(end) { end += 1 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: (end - first) * rowHeight, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { composition = nil; return nil }
        var quads: [NeoGPUScene.Quad] = []
        quads.reserveCapacity(end - first)
        for index in first..<end {
            let row = scene.rows[index]
            guard var art = cache[row.id] else { composition = nil; return nil }
            useCounter &+= 1; art.used = useCounter; cache[row.id] = art
            let fill = SIMD4<Float>(20/255, 20/255, 20/255, 1)
            quads.append(.init(bounds: .init(0, Float((index - first) * rowHeight), Float(width), Float(rowHeight)),
                               color: fill, texture: art.texture))
        }
        do {
            let rows = try NeoGPUScene(device: device, revision: sceneRevision, quads: quads)
            try gpu.encode(rows, into: texture, command: command)
            let result = Composition(rows: first..<end, revision: contentRevision, scale: scale, texture: texture)
            composition = result; highlightedScene = nil; highlightKey = nil; compositionBuilds += 1
            return result
        } catch { composition = nil; return nil }
    }

    /// Draw the immutable, opaque base first, then replace highlighted rows using
    /// their original transparent artwork and new fill. This preserves the reference
    /// shader's exact antialiasing and paint order without copying or allocating textures.
    private func displayScene(_ composition: Composition, scene: Scene) throws -> NeoGPUScene {
        // A project replacement can shrink the model before native table layout
        // finishes. Never trust retained strip bounds or highlight indices then.
        guard composition.rows.lowerBound >= 0, composition.rows.upperBound <= scene.rows.count else {
            invalidateRowContent()
            throw NeoGPUScene.Failure.invalidGeometry
        }
        let key = Highlights(selected: scene.selected, hovered: scene.hovered, active: scene.active)
        if key == highlightKey, let highlightedScene { return highlightedScene }
        let width = Float(composition.texture.width), height = Float(24 * composition.scale)
        var quads: [NeoGPUScene.Quad] = [.init(bounds: .init(0, 0, width, Float(composition.texture.height)), texture: composition.texture)]
        var indices = Set([scene.selected])
        if let hovered = scene.hovered { indices.insert(hovered) }
        if activeLookup?.revision != contentRevision || activeLookup?.url != scene.active {
            let index = scene.active.flatMap { active in scene.rows.firstIndex { $0.item.id == active } }
            activeLookup = (contentRevision, scene.active, index)
        }
        if let index = activeLookup?.index { indices.insert(index) }
        for index in indices.sorted() where composition.rows.contains(index) {
            guard let art = cache[scene.rows[index].id], art.row == scene.rows[index],
                  art.width == composition.texture.width, art.scale == composition.scale else {
                self.composition = nil; highlightedScene = nil
                throw NeoGPUScene.Failure.allocation // Restore native rows until artwork is ready.
            }
            let selected = index == scene.selected || scene.rows[index].item.id == scene.active
            let value: Float = selected ? 35/255 : 33/255
            quads.append(.init(bounds: .init(0, Float(index - composition.rows.lowerBound) * height, width, height),
                               color: .init(value, value, value, 1), texture: art.texture))
        }
        let result = try NeoGPUScene(device: device, revision: sceneRevision, quads: quads)
        highlightedScene = result; highlightKey = key
        return result
    }

    private func encodeRows(scene: Scene, visible: Range<Int>, y: CGFloat, width: Int, scale: CGFloat,
                            encoder: MTLRenderCommandEncoder) {
        for index in visible {
            let row = scene.rows[index]
            guard var art = cache[row.id] else { continue }
            useCounter &+= 1; art.used = useCounter; cache[row.id] = art
            let topPixel = ((CGFloat(index) * 24 - y) * scale).rounded()
            let bottomPixel = topPixel + (24 * scale).rounded()
            let top = topPixel
            let bottom = bottomPixel
            let vertices: [SIMD4<Float>] = [
                .init(0, Float(top), 0, 0), .init(Float(width), Float(top), 1, 0), .init(0, Float(bottom), 0, 1),
                .init(Float(width), Float(top), 1, 0), .init(Float(width), Float(bottom), 1, 1), .init(0, Float(bottom), 0, 1)]
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            var fill: SIMD4<Float> = (index == scene.selected || row.item.id == scene.active) ? .init(repeating: 35/255) :
                (index == scene.hovered ? .init(repeating: 33/255) : .init(repeating: 20/255))
            fill.w = 1
            encoder.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(art.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func capturePixels(_ texture: MTLTexture, command: MTLCommandBuffer, completion: @escaping (CGImage) -> Void) {
        let stride = (texture.width * 4 + 255) / 256 * 256
        guard let buffer = device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
        blit.endEncoding()
        command.addCompletedHandler { _ in
            let data = Data(bytes: buffer.contents(), count: stride * texture.height)
            guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: texture.width, height: texture.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func schedule(_ row: ExplorerRow, width: Int, scale: CGFloat) {
        let key = JobKey(id: row.id, width: width, scale: scale, generation: generation)
        guard jobs.count < 16, !jobs.contains(key) else { return }
        jobs.insert(key)
        // Resolve AppKit symbols/colors/fonts on the main thread. CoreText rasterization
        // and bitmap allocation run on the worker; there is no per-frame text shaping.
        let look = SemanticFileIcon.appearance(url: row.item.url, directory: row.item.isDirectory, expanded: row.expanded)
        let symbol = Self.symbol(look.symbol, size: 12, width: 17, height: 16, scale: scale)
        let chevron = row.item.isDirectory ? Self.symbol(row.expanded ? "chevron.down" : "chevron.right", size: 8, width: 10, height: 8, scale: scale) : nil
        let text = NSColor(row.git?.color ?? NeoLinkTheme.textPrimary).cgColor
        let iconColor = NSColor(look.color).cgColor
        let secondary = NSColor(NeoLinkTheme.textSecondary).cgColor
        let badgeColor = NSColor(row.git?.color ?? NeoLinkTheme.textSecondary).cgColor
        let diagnosticColor = NSColor(row.diagnostics.errors > 0 ? NeoLinkTheme.error : NeoLinkTheme.warning).cgColor
        let nameFont = NSFont.systemFont(ofSize: 12) as CTFont
        let smallFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold) as CTFont
        let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium) as CTFont
        let rasterEpoch = rasterEpoch
        worker.async { [weak self] in
            guard rasterEpoch.matches(key.generation) else { return }
            let art = Self.raster(row, width: width, scale: scale, abbreviation: look.abbreviation, symbol: symbol,
                chevron: chevron, text: text, iconColor: iconColor, secondary: secondary, badgeColor: badgeColor,
                diagnosticColor: diagnosticColor, nameFont: nameFont, smallFont: smallFont, badgeFont: badgeFont)
            guard rasterEpoch.matches(key.generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.jobs.remove(key)
                guard key.generation == self.generation, let art else { return }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: art.width, height: art.height, mipmapped: false)
                descriptor.usage = .shaderRead; descriptor.storageMode = .shared
                guard let texture = self.device.makeTexture(descriptor: descriptor) else { self.uncover(); return }
                art.pixels.withUnsafeBytes { pixels in
                    texture.replace(region: MTLRegionMake2D(0, 0, art.width, art.height), mipmapLevel: 0,
                                    withBytes: pixels.baseAddress!, bytesPerRow: art.width * 4)
                }
                self.useCounter &+= 1
                self.cache[row.id] = Artwork(row: row, width: width, scale: scale, texture: texture, used: self.useCounter)
                if self.cache.count > Self.cacheLimit, let oldest = self.cache.min(by: { $0.value.used < $1.value.used })?.key {
                    self.cache.removeValue(forKey: oldest)
                }
                let budget = max(32 * 1024 * 1024, width * Int(self.bounds.height * scale) * 16)
                var bytes = self.cache.values.reduce(0) { $0 + $1.texture.width * $1.texture.height * 4 }
                while bytes > budget, let oldest = self.cache.min(by: { $0.value.used < $1.value.used }) {
                    bytes -= oldest.value.texture.width * oldest.value.texture.height * 4
                    self.cache.removeValue(forKey: oldest.key)
                }
                self.refreshAfterArtworkBatch()
            }
        }
    }

    private func refreshAfterArtworkBatch() {
        guard !artworkRefreshScheduled else { return }
        artworkRefreshScheduled = true
        let currentGeneration = generation
        // A directory can finish dozens of rasters together. Re-check the viewport
        // once for that batch instead of scheduling the entire prefetch range per row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.artworkRefreshScheduled = false
            self.invalidateScene(contentChanged: false)
        }
    }

    private static var symbols: [String: CGImage] = [:]
    private static func symbol(_ name: String, size: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(name):\(size):\(width):\(height):\(scale)"
        if let image = symbols[key] { return image }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular)),
              let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        symbols[key] = image
        return image
    }

    nonisolated private static func raster(_ row: ExplorerRow, width: Int, scale: CGFloat, abbreviation: String?, symbol: CGImage?,
        chevron: CGImage?, text: CGColor, iconColor: CGColor, secondary: CGColor, badgeColor: CGColor, diagnosticColor: CGColor,
        nameFont: CTFont, smallFont: CTFont, badgeFont: CTFont) -> Raster? {
        let height = Int(24 * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if row.git == .ignored { context.setAlpha(0.55) }
        func line(_ string: String, font: CTFont, color: CGColor, x: CGFloat, width: CGFloat, centered: Bool = false) {
            guard width > 0 else { return }
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                           NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let fitted = CTLineCreateTruncatedLine(full, Double(width), .middle, token) ?? full
            let extent = CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil))
            context.saveGState()
            context.clip(to: CGRect(x: x, y: 0, width: width, height: 24))
            context.textPosition = CGPoint(x: x + (centered ? max(0, (width - extent) / 2) : 0), y: CTFontGetSize(font) == 12 ? 7 : 8)
            CTLineDraw(fitted, context)
            context.restoreGState()
        }
        func icon(_ image: CGImage?, rect: CGRect, color: CGColor) {
            guard let image else { return }
            context.saveGState(); context.clip(to: rect, mask: image)
            context.setFillColor(color); context.fill(rect); context.restoreGState()
        }
        let inset = 8 + CGFloat(row.depth) * 12
        icon(chevron, rect: CGRect(x: inset, y: 8, width: 10, height: 8), color: secondary)
        if let abbreviation { line(abbreviation, font: smallFont, color: iconColor, x: inset + 15, width: 17, centered: true) }
        else { icon(symbol, rect: CGRect(x: inset + 15, y: 4, width: 17, height: 16), color: iconColor) }
        var right = CGFloat(width) / scale - 8
        for (value, color) in [(row.git == nil || row.git == .ignored ? "" : row.git!.rawValue, badgeColor),
                               (row.diagnostics.count == 0 ? "" : String(row.diagnostics.count), diagnosticColor)] where !value.isEmpty {
            let extent = CGFloat(value.count) * 7
            right -= extent; line(value, font: badgeFont, color: color, x: right, width: extent); right -= 7
        }
        line(row.name, font: nameFont, color: text, x: inset + 37, width: max(0, right - inset - 37))
        guard let data = context.data else { return nil }
        return Raster(width: width, height: height, pixels: Data(bytes: data, count: width * height * 4))
    }

    nonisolated private static func pipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V explorer_vertex(uint i [[vertex_id]], constant float4 *v [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
            V out; out.position = float4(v[i].x / size.x * 2 - 1, 1 - v[i].y / size.y * 2, 0, 1); out.uv = v[i].zw; return out;
        }
        fragment float4 explorer_fragment(V in [[stage_in]], texture2d<float> art [[texture(0)]], constant float4 &fill [[buffer(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            float4 ink = art.sample(s, in.uv); return ink + fill * (1 - ink.a);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "explorer_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "explorer_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// The command's private vertex bytes and immutable textures need no main-thread cleanup.
/// The next display callback can proceed as soon as Metal completes the previous command.
final class ExplorerFrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return !busy }
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }
    func release() { lock.lock(); busy = false; lock.unlock() }
}

/// Width changes obsolete queued raster work before it allocates bitmaps or returns
/// textures to the main thread. At most one already-running raster finishes unused.
private final class ExplorerRasterEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    func set(_ value: UInt64) { lock.lock(); generation = value; lock.unlock() }
    func matches(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }
}
