import AppKit
import Combine
@preconcurrency import Metal
import QuartzCore

/// SwiftUI owns its internal layer hierarchy. Keep hosted content and the GPU
/// overlay as siblings so SwiftUI cannot cover the presentation surface.
@MainActor
final class WorkspaceContentController: NSViewController {
    init(hosting: NSViewController, size: NSSize) {
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Content acknowledgements of drawables the compositor dropped.
///
/// Two different facts are kept apart. "This pane revision and position appeared"
/// belongs to the one drawable that carried it and is never replayed: a dropped
/// frame's position was not shown, and its ownership effects (hiding the native
/// layer, covering native rows) must not run for a drawable that omits the pane.
/// "This input or selection was satisfied by later visible content" may be
/// deferred: pane textures are retained, so a *later-submitted* drawable that
/// reaches the display *and carries the same pane* shows the same or newer
/// content. Entries are matched by pane and frame order, oldest first, bounded.
struct DeferredPresentations {
    struct Entry {
        let pane: ObjectIdentifier
        /// Submission order of the dropped drawable.
        let frame: UInt64
        let acknowledge: (Double) -> Void
    }
    private var pending: [Entry] = []
    static let limit = 64
    var count: Int { pending.count }
    mutating func dropped(_ entries: [Entry]) {
        pending.append(contentsOf: entries)
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
    }
    /// Acknowledgements satisfied by a drawable that reached the display. Only
    /// panes it carried, and only frames submitted before it: completion handlers
    /// can arrive out of order, and an older drawable does not show newer content.
    /// Other panes' entries stay for a drawable that does carry them.
    mutating func presented(frame: UInt64, carrying panes: Set<ObjectIdentifier>) -> [(Double) -> Void] {
        var satisfied: [(Double) -> Void] = []
        pending.removeAll { entry in
            guard entry.frame < frame, panes.contains(entry.pane) else { return false }
            satisfied.append(entry.acknowledge)
            return true
        }
        return satisfied
    }
    /// A pane that left the workspace for good can no longer be satisfied.
    mutating func retire(_ pane: ObjectIdentifier) { pending.removeAll { $0.pane == pane } }

    /// One drawable's completion. Returns the callbacks to run, in order.
    /// - `presentedTime == 0`: dropped. Defer its content acknowledgements only.
    /// - shown while the workspace still owns the same client set (`current`):
    ///   earlier satisfied acknowledgements, then this drawable's own callbacks.
    /// - shown after an overlay, fallback or client-set change: content
    ///   acknowledgements only; ownership callbacks would hide native fallback.
    mutating func complete(presentedTime: Double, frame: UInt64, current: Bool,
                           carried: Set<ObjectIdentifier>, presented: [(Double) -> Void],
                           acknowledged: [Entry]) -> [(Double) -> Void] {
        guard presentedTime > 0 else { dropped(acknowledged); return [] }
        let satisfied = self.presented(frame: frame, carrying: carried)
        return satisfied + (current ? presented : acknowledged.map(\.acknowledge))
    }
}

@MainActor
protocol NeoGPUClient: AnyObject {
    var gpuInputView: NSView? { get }
    func gpuPrepare(time: Double, command: MTLCommandBuffer) -> NeoGPUNode?
    func gpuSetHosted(_ hosted: Bool)
    func gpuReleaseHiddenResources()
    func gpuLatchOutput()
}

extension NeoGPUClient {
    func gpuReleaseHiddenResources() {}
    func gpuLatchOutput() {}
}

struct NeoGPUNode {
    let scene: NeoGPUScene
    var translation: SIMD2<Float> = .zero
    var needsAnotherFrame = false
    var traceSelection: UInt64 = 0
    let presented: (Double) -> Void
    /// Run instead of `presented` when the drawable reached the display after the workspace's client set
    /// changed: only the truthful "this content was presented" acknowledgement, never ownership changes.
    var acknowledged: ((Double) -> Void)?
}

extension Notification.Name {
    static let neoGPUWorkspaceReady = Notification.Name("NeoGPUWorkspaceReady")
}

/// One supplied drawable, GPU command buffer and presentation for the coding
/// workspace. Native views remain the input/accessibility adapters underneath.
@MainActor
final class NeoGPUWorkspace: NSView {
    private final class Client {
        weak var value: (any NeoGPUClient)?
        init(_ value: any NeoGPUClient) { self.value = value }
    }
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: NeoGPURenderer
    private var clients: [ObjectIdentifier: Client] = [:]
    private var source: FrameClock?
    private let slot = ExplorerFrameSlot()
    private var observers: [NSObjectProtocol] = []
    private var refreshObservation: AnyCancellable?
    private(set) var continuousRefresh: Bool
    private(set) var enabled = true
    private(set) var suspended = false
    private(set) var presentedFrames: UInt64 = 0
    private(set) var droppedDrawables: UInt64 = 0
    private var deferredPresentations = DeferredPresentations()
    private var submittedFrames: UInt64 = 0
    private(set) var presentationTiming = FrameTiming()
    func resetPresentationTiming() { presentationTiming = FrameTiming() }
    private(set) var lastNodeCount = 0
    private var generation: UInt64 = 0
    private(set) var drawCallbacks = 0
    private var presentedLastDraw = false
    /// Refreshes the direct clock skipped because enough frames already waited for the display.
    var skippedForQueue: Int { if #available(macOS 14, *) { return (source as? NeoGPUDirectFrameSource)?.skippedForQueue ?? 0 }; return 0 }
    var diagnostics: String { "enabled=\(enabled) suspended=\(suspended) window=\(window != nil) hidden=\(isHidden) bounds=\(bounds) clients=\(clients.count) callbacks=\(drawCallbacks) nodes=\(lastNodeCount) frames=\(presentedFrames)" }
    static var allowsOffscreenTesting = false
    var captureNextFrame: ((CGImage) -> Void)?

    static func forWindow(_ window: NSWindow?) -> NeoGPUWorkspace? {
        guard let root = (window as? WorkspaceWindow)?.gpuWorkspace, root.enabled, !root.suspended else { return nil }
        return root
    }

    init?(window: WorkspaceWindow, device: MTLDevice, preferences: TerminalRenderingPreferences? = nil) {
        guard #available(macOS 14, *), let content = window.contentView,
              let renderer = NeoGPUResources.shared.renderer(device: device), let queue = device.makeCommandQueue() else { return nil }
        let preferences = preferences ?? .shared
        self.device = device; self.renderer = renderer; self.queue = queue
        continuousRefresh = preferences.continuousRefresh
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]; wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        content.addSubview(self, positioned: .above, relativeTo: nil)
        configureSource()
        refreshObservation = preferences.$continuousRefresh.dropFirst().sink { [weak self] enabled in
            self?.continuousRefresh = enabled
            self?.wake()
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configureSource(); self?.wake() }
            })
        }
        window.frames.register(ObjectIdentifier(self), interaction: { [weak self] in self?.wake() }) { [weak self] in
            guard let self, self.enabled, !self.suspended else { return nil }
            return ("NeoGPU workspace", self.presentedFrames)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false; layer.framebufferOnly = !Self.allowsOffscreenTesting
        layer.displaySyncEnabled = true; layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        return layer
    }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); wake() }

    private func configureSource() {
        presentationTiming.pause()
        source?.invalidate(); source = nil
        guard !Self.allowsOffscreenTesting else { return }
        guard #available(macOS 14, *), let layer = layer as? CAMetalLayer else { return }
        let rate = WindowFrameScheduler.rate(for: window?.screen?.maximumFramesPerSecond ?? 60)
        switch NeoGPUPresentation.current {
        case .direct:
            source = NeoGPUDirectFrameSource(layer: layer, view: self, rate: rate) { [weak self] drawable in
                guard let self else { return (false, false) }
                self.presentedLastDraw = false
                let keepRunning = self.draw(drawable)
                return (keepRunning, self.presentedLastDraw)
            }
        case .displayLink:
            source = NeoGPUFrameSource(layer: layer, rate: rate) { [weak self] drawable in
                self?.draw(drawable) ?? false
            }
        }
    }
    func register(_ client: any NeoGPUClient) {
        let id = ObjectIdentifier(client)
        clients = clients.filter { $0.value.value != nil }
        let first = clients.isEmpty
        if clients[id] == nil { generation &+= 1; SelectionTrace.mark(SelectionTrace.current, "workspace.generation", once: false, fields: ["reason": "register \(type(of: client))"]); clients[id] = Client(client); client.gpuSetHosted(true) }
        if first {
            isHidden = false
            (window as? WorkspaceWindow)?.frames.setWorkspaceDriver { [weak self] in self?.wake() }
        }
        wake()
    }
    func unregister(_ client: any NeoGPUClient) {
        if clients.removeValue(forKey: ObjectIdentifier(client)) != nil {
            generation &+= 1
            SelectionTrace.mark(SelectionTrace.current, "workspace.generation", once: false, fields: ["reason": "unregister \(type(of: client))"])
            client.gpuSetHosted(false)
            if clients.isEmpty {
                isHidden = true; source?.stop()
                (window as? WorkspaceWindow)?.frames.setWorkspaceDriver(nil)
            } else { wake() }
        }
    }
    func wake() {
        guard enabled, !suspended, !clients.isEmpty, let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), let layer = layer as? CAMetalLayer else {
            source?.stop(); presentationTiming.pause(); return
        }
        let scale = window.backingScaleFactor
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if layer.contentsScale != scale || layer.drawableSize != size {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if layer.contentsScale != scale { layer.contentsScale = scale }
            if layer.drawableSize != size { layer.drawableSize = size }
            CATransaction.commit()
        }
        source?.start()
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        generation &+= 1
        suspended = value; isHidden = value
        presentationTiming.pause()
        let existing = clients.values.compactMap(\.value)
        clients.removeAll()
        existing.forEach { $0.gpuSetHosted(false) }
        if value { source?.stop(); (window as? WorkspaceWindow)?.frames.setWorkspaceDriver(nil) }
        else {
            NotificationCenter.default.post(name: .neoGPUWorkspaceReady, object: window); wake() }
    }
    func fail() {
        generation &+= 1
        enabled = false; source?.invalidate(); source = nil; isHidden = true
        (window as? WorkspaceWindow)?.frames.setWorkspaceDriver(nil)
        let existing = clients.values.compactMap(\.value); clients.removeAll()
        existing.forEach { $0.gpuSetHosted(false) }
    }

    func drawOffscreenForTesting() {
        guard Self.allowsOffscreenTesting, slot.isAvailable, let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        guard let drawable = layer.nextDrawable() else { return }
        _ = draw(drawable, allowOffscreen: true)
    }

    private func draw(_ drawable: CAMetalDrawable, allowOffscreen: Bool = false) -> Bool {
        drawCallbacks += 1
        guard enabled, !suspended, let window,
              allowOffscreen || (window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)) else { return false }
        guard slot.isAvailable else { return true }
        let scale = window.backingScaleFactor
        guard drawable.texture.width == Int((bounds.width * scale).rounded()),
              drawable.texture.height == Int((bounds.height * scale).rounded()) else { wake(); return true }
        guard let command = queue.makeCommandBuffer() else { fail(); return false }
        var nodes: [(NeoGPUNode, SIMD2<Float>, MTLScissorRect, ObjectIdentifier)] = []
        nodes.reserveCapacity(clients.count)
        let time = source?.targetTimestamp ?? CACurrentMediaTime()
        // Admit PTY bytes before deciding which pane is visible. In particular,
        // the matching editor marker may make a previously hidden pane ready.
        // Snapshot clients: parsing can synchronously change focus/registration.
        let latchingClients = clients.values.compactMap(\.value)
        latchingClients.forEach { $0.gpuLatchOutput() }
        (window as? WorkspaceWindow)?.frames.prepareWorkspace(at: time)
        if clients.values.contains(where: { $0.value == nil }) {
            for (id, entry) in clients where entry.value == nil { deferredPresentations.retire(id) }
            clients = clients.filter { $0.value.value != nil }
        }
        for entry in clients.values {
            guard let client = entry.value else { continue }
            guard let view = client.gpuInputView, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  !view.visibleRect.isEmpty else { client.gpuReleaseHiddenResources(); continue }
            let rect = view.convert(view.bounds, to: self)
            // Newer AppKit views can report a visibleRect beyond their bounds
            // when clipsToBounds is false. GPU panes must never paint there.
            let visible = view.convert(view.visibleRect.intersection(view.bounds), to: self).intersection(bounds)
            guard !visible.isEmpty, let node = client.gpuPrepare(time: time, command: command) else { continue }
            let x = max(0, Int(floor(visible.minX * scale))), y = max(0, Int(floor(visible.minY * scale)))
            let right = min(drawable.texture.width, Int(ceil(visible.maxX * scale)))
            let bottom = min(drawable.texture.height, Int(ceil(visible.maxY * scale)))
            guard right > x, bottom > y else { continue }
            nodes.append((node, .init(Float((rect.minX * scale).rounded()), Float((rect.minY * scale).rounded())),
                          MTLScissorRect(x: x, y: y, width: right - x, height: bottom - y), ObjectIdentifier(client)))
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { fail(); return false }
        for (node, origin, clip, _) in nodes {
            encoder.setScissorRect(clip)
            renderer.encode(node.scene, encoder: encoder, viewport: .init(Float(drawable.texture.width), Float(drawable.texture.height)),
                            translation: origin + node.translation)
        }
        encoder.endEncoding()
        lastNodeCount = nodes.count
        if let capture = captureNextFrame, !drawable.texture.isFramebufferOnly {
            captureNextFrame = nil
            NeoGPUCapture.encode(drawable.texture, command: command, completion: capture)
        }
        guard slot.acquire() else { return true }
        let callbacks = nodes.map { $0.0.presented }, generation = self.generation
        submittedFrames &+= 1
        let frame = submittedFrames, carried = Set(nodes.map(\.3))
        let deferrable = nodes.compactMap { node in
            node.0.acknowledged.map { DeferredPresentations.Entry(pane: node.3, frame: frame, acknowledge: $0) }
        }
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            DispatchQueue.main.async {
                guard let self else { return }
                // Dropped (time == 0): nothing it carried was shown, so no position,
                // revision or ownership callback runs; its content acknowledgements
                // wait for a later drawable carrying the same pane. A completion
                // arriving after an overlay, fallback or tab change must not hide a
                // surface that returned to native ownership, nor discard
                // acknowledgements of newer frames or of panes it did not carry.
                let current = self.enabled && !self.suspended && self.generation == generation
                if time > 0 {
                    self.presentedFrames &+= 1
                    // Visibility transitions explicitly pause this series. Keep even
                    // long visible-window stalls instead of silently filtering them.
                    if current { self.presentationTiming.record(timestamp: time, work: 0, includeLongIntervals: true) }
                } else { self.droppedDrawables &+= 1 }
                self.deferredPresentations.complete(presentedTime: time, frame: frame, current: current, carried: carried,
                                                    presented: callbacks, acknowledged: deferrable).forEach { $0(time) }
            }
        }
        let slot = self.slot
        command.addCompletedHandler { [weak self] buffer in
            slot.release()
            if buffer.status == .error { DispatchQueue.main.async { self?.fail() } }
        }
        if SelectionTrace.enabled {
            for token in Set(nodes.map { $0.0.traceSelection }).filter({ $0 > 0 }) { SelectionTrace.mark(token, "frame.submitted") }
        }
        presentedLastDraw = true
        command.present(drawable); command.commit()
        // Repeat only at the owning display-link deadline. Retained pane textures
        // avoid reshaping unchanged text; do not enqueue timer-driven extra frames.
        return (continuousRefresh && !nodes.isEmpty) || nodes.contains { $0.0.needsAnotherFrame }
            || ((window as? WorkspaceWindow)?.frames.isRunning ?? false)
    }
}
