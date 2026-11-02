import AppKit
import QuartzCore

/// A separate native panel samples counters at 2 Hz. It never publishes a
/// per-frame ObservableObject change through the workspace's SwiftUI tree.
@MainActor
final class PerformanceMonitor: NSObject, NSWindowDelegate {
    static let shared = PerformanceMonitor()
    private var panel: NSPanel?
    private weak var frames: WindowFrameScheduler?
    private let text = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var previous: [ObjectIdentifier: (name: String, count: UInt64)] = [:]
    private var lastSample = 0.0

    func show(for window: NSWindow?) {
        frames = WindowFrameScheduler.forWindow(window)
        previous = frames?.gpuSamples ?? [:]
        lastSample = CACurrentMediaTime()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Performance"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isSelectable = true
            text.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(text)
            if let content = panel.contentView {
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                    text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                    text.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
                ])
            }
            panel.center()
            self.panel = panel
        }
        update()
        panel?.orderFront(nil)
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard let frames else { text.stringValue = "No workspace window is active."; return }
        let now = CACurrentMediaTime(), elapsed = now - lastSample
        let samples = frames.gpuSamples
        let rates = samples.sorted { $0.value.name < $1.value.name }.map { id, value -> String in
            guard let old = previous[id], elapsed >= 0.1, value.count >= old.count else { return "\(value.name): sampling…" }
            let rate = Double(value.count - old.count) / elapsed
            return "\(value.name): \(String(format: "%.1f", rate)) presented GPU frames/s"
        }
        text.stringValue = frames.summary + "\n\n" + (rates.isEmpty ? "No visible Metal surface." : rates.joined(separator: "\n"))
            + "\n\nGPU rates count drawables presented; an unchanged surface presents nothing. Frame work covers scheduled updates and submission."
        previous = samples; lastSample = now
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; previous = [:] }
}
