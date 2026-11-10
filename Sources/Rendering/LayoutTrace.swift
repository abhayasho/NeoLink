import AppKit
import QuartzCore

/// Opt-in attribution of main-thread work around selections and divider drags
/// (`NEOLINK_SELECTION_TRACE`). It answers "which views were re-evaluated or
/// laid out, and did their inputs or bounds actually change" without a profiler.
/// Events join the current selection generation; nothing is recorded otherwise.
enum LayoutTrace {
    static let enabled = SelectionTrace.enabled
    private static var installed = false
    private static var began = 0.0
    /// Layout events outside any selection (a divider drag) still need a generation to join.
    static var token: UInt64 { max(SelectionTrace.current, 1) }

    /// SwiftUI `body` evaluation or representable update.
    @inline(__always) static func body(_ name: @autoclosure () -> String) {
        guard enabled else { return }
        SelectionTrace.mark(token, "body." + name(), once: false)
    }
    /// AppKit layout of a native pane, with whether its size really changed.
    @inline(__always) static func layout(_ name: @autoclosure () -> String, size: CGSize, changed: Bool) {
        guard enabled else { return }
        SelectionTrace.mark(token, "layout." + name(), once: false,
                            fields: ["width": size.width, "height": size.height, "changed": changed])
    }
    /// Records every main run-loop pass that kept the thread busy for 2 ms or more.
    @MainActor static func install() {
        guard enabled, !installed else { return }
        installed = true
        // Core Animation commits (and SwiftUI updates) run in before-waiting observers,
        // so the span must open before every other observer and close after all of them.
        let opening = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.entry, .afterWaiting]).rawValue, true, CFIndex.min) { _, _ in
            began = CACurrentMediaTime()
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, true, CFIndex.max) { _, _ in
            guard began > 0 else { return }
            let busy = CACurrentMediaTime() - began
            if busy >= 0.002 {
                SelectionTrace.mark(token, "main.busy", at: began, once: false, fields: ["ms": (busy * 10_000).rounded() / 10])
            }
            began = 0
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), opening, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
