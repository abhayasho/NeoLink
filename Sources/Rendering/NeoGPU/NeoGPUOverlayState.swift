import AppKit
import SwiftUI

/// Native in-window palettes must paint above hosted GPU panes. While one is
/// open, adapters use their independent surface path without restarting models.
struct NeoGPUOverlayState: NSViewRepresentable {
    let suspended: Bool
    func makeNSView(context: Context) -> Bridge { Bridge() }
    func updateNSView(_ view: Bridge, context: Context) { view.suspended = suspended; view.apply() }
    final class Bridge: NSView {
        var suspended = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window = window as? WorkspaceWindow else { return }
            window.gpuOverlayPresented = suspended
            window.gpuWorkspace?.setSuspended(suspended)
        }
    }
}
