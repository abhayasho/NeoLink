import AppKit
import Combine
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
/// The upstream renderer owns dirty rows, drawable lifetimes, recovery, and idle draws;
/// do not add a second timer or a continuously running display link around it.
@MainActor
final class TerminalRendering {
    private weak var view: InteractiveTerminalView?
    private let preferences: TerminalRenderingPreferences
    private var observation: AnyCancellable?
    private var attemptedGPU = false
    private(set) var failure: String?

    init(view: InteractiveTerminalView, preferences: TerminalRenderingPreferences? = nil) {
        self.view = view
        self.preferences = preferences ?? .shared
        observation = self.preferences.$useGPU.dropFirst().sink { [weak self] enabled in
            // @Published emits before the stored value changes; use the emitted value.
            self?.apply(enabled: enabled, retry: true)
        }
    }

    func attachToWindow() { apply(enabled: preferences.useGPU, retry: false) }

    private func apply(enabled: Bool, retry: Bool) {
        guard let view, view.window != nil else { return }
        if retry { attemptedGPU = false; failure = nil }
        if !enabled {
            try? view.setUseMetal(false)
            attemptedGPU = false
            return
        }
        guard !attemptedGPU else { return }
        attemptedGPU = true
        // Keep unchanged row geometry cached for editing and ordinary terminal output.
        view.metalBufferingMode = .perRowPersistent
        do {
            try view.setUseMetal(true)
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
        return "\(status)\nPresented GPU frames: \(view.metalRendererStatus.presentedFrameCount)\nDisplay maximum refresh rate: \(refresh) Hz\n\nThe display limit is not a measured application frame rate. Rendering runs on demand; idle views do not continuously redraw."
    }
}
