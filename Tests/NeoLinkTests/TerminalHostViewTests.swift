import AppKit
import SwiftTerm
import XCTest
@testable import NeoLink

final class TerminalHostViewTests: XCTestCase {
    func testTabRoundtripPreservesNativeScreenAndScrollbackAcrossZeroLayout() async throws {
        try await MainActor.run {
            let controller = TabsController(useNeovim: false)
            let first = try XCTUnwrap(controller.selectedTerminalTab)
            controller.openLocalTab()
            let second = try XCTUnwrap(controller.selectedTerminalTab)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let size = NSSize(width: 800, height: 480)
            let host = TerminalHostView(frame: NSRect(origin: .zero, size: size)) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
                created[tab.id] = view
                return view
            }
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: first.id)
            let firstView = try XCTUnwrap(created[first.id])
            firstView.feed(text: (0..<70).map { "SCROLLBACK_LINE_\($0)\r\n" }.joined() + "VISIBLE_MARKER\r\n")
            let before = firstView.terminal.getBufferAsData(kind: .normal)
            let columns = firstView.terminal.cols
            let rows = firstView.terminal.rows
            XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("VISIBLE_MARKER"))
            XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("SCROLLBACK_LINE_0"))

            // A document tab hides every terminal without discarding its native buffer.
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: nil)
            XCTAssertTrue(firstView.isHidden)
            XCTAssertTrue(firstView.superview === host)
            XCTAssertEqual(firstView.terminal.getBufferAsData(kind: .normal), before)

            host.synchronize(tabs: controller.terminalTabs, selectedTabID: second.id)
            XCTAssertTrue(firstView.isHidden)
            XCTAssertTrue(firstView.superview === host)
            host.setFrameSize(.zero)
            XCTAssertEqual(firstView.terminal.cols, columns)
            XCTAssertEqual(firstView.terminal.rows, rows)
            host.setFrameSize(size)
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: first.id)

            XCTAssertFalse(firstView.isHidden)
            XCTAssertTrue(created[first.id] === firstView)
            XCTAssertEqual(firstView.terminal.getBufferAsData(kind: .normal), before)
            XCTAssertEqual(firstView.terminal.cols, columns)
            XCTAssertEqual(firstView.terminal.rows, rows)
            XCTAssertEqual(created.count, 2)
        }
    }

    func testCoveredTerminalStaysMountedAtItsSizeAndNeverTakesFocus() async throws {
        try await MainActor.run {
            let controller = TabsController(useNeovim: false)
            let shell = try XCTUnwrap(controller.selectedTerminalTab)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Covered-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("a.txt"); try Data("a".utf8).write(to: file)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let size = NSSize(width: 800, height: 480)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            let host = TerminalHostView(frame: NSRect(origin: .zero, size: size)) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size)); created[tab.id] = view; return view
            }
            window.contentView?.addSubview(host)
            controller.terminalPane = host
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: controller.shownTerminalTab?.id, isActive: true)
            let view = try XCTUnwrap(created[shell.id])
            let grid = (view.terminal.cols, view.terminal.rows)

            // Selecting a document keeps the same terminal as the pane's content...
            controller.openFile(file)
            XCTAssertNotNil(controller.selectedTab?.document)
            XCTAssertEqual(controller.shownTerminalTab?.id, shell.id, "the covered terminal (and its status bar) stays mounted")
            // ...and the non-Neovim document path leaves hiding to SwiftUI's update.
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: controller.shownTerminalTab?.id, isActive: false, immediate: true)
            XCTAssertTrue(host.isHidden, "an immediate switch hides the pane before SwiftUI runs")
            XCTAssertFalse(view.isHidden, "the terminal inside it is not unmounted or resized")
            XCTAssertEqual(view.frame.size, size)
            XCTAssertEqual(view.terminal.cols, grid.0); XCTAssertEqual(view.terminal.rows, grid.1)
            host.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertFalse(window.firstResponder === view, "a covered terminal never takes focus from the document")

            // Returning shows it at once at the same grid; SwiftUI's later identical call changes nothing.
            controller.selectedTabID = shell.id
            XCTAssertFalse(host.isHidden, "the selection itself shows the pane")
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: shell.id, isActive: true)
            XCTAssertEqual(view.terminal.cols, grid.0); XCTAssertEqual(view.terminal.rows, grid.1)
            XCTAssertEqual(created.count, 1)
        }
    }

    @MainActor func testCoveredTerminalDefersGridResizeUntilQuietOrShown() async throws {
        do {
            let controller = TabsController(useNeovim: false)
            let shell = try XCTUnwrap(controller.selectedTerminalTab)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let size = NSSize(width: 800, height: 480)
            let host = TerminalHostView(frame: NSRect(origin: .zero, size: size)) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size)); created[tab.id] = view; return view
            }
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: shell.id, isActive: true)
            let view = try XCTUnwrap(created[shell.id])
            let columns = view.terminal.cols
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: shell.id, isActive: false, immediate: true)
            XCTAssertTrue(host.isHidden)

            // A divider drag while a document covers the shell: many sizes, no reflow per step.
            for width in stride(from: 790.0, through: 600.0, by: -10.0) { host.setFrameSize(NSSize(width: width, height: 480)) }
            XCTAssertEqual(view.frame.width, 800, "a covered terminal is not resized at every step")
            XCTAssertEqual(view.terminal.cols, columns)

            // Shown again before the quiet period ends: it takes the current size at once.
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: shell.id, isActive: true, immediate: true)
            XCTAssertEqual(view.frame.width, 600)
            XCTAssertLessThan(view.terminal.cols, columns)

            // Covered again and resized: once the drag goes quiet the final size is applied once.
            host.synchronize(tabs: controller.workspaceTerminalTabs, selectedTabID: shell.id, isActive: false, immediate: true)
            host.setFrameSize(NSSize(width: 700, height: 480)); host.setFrameSize(NSSize(width: 720, height: 480))
            XCTAssertEqual(view.frame.width, 600)
            // Suspend so the main queue can run the deferred resize.
            try await Task.sleep(nanoseconds: UInt64((CoveredPaneResize.quiet + 0.15) * 1_000_000_000))
            XCTAssertEqual(view.frame.width, 720, "the final size is applied after the drag goes quiet")
        }
    }

    func testHostLaunchesOnlySelectedTabsAndKeepsHiddenFrameUntilSelected() async throws {
        try await MainActor.run {
            let controller = TabsController(useNeovim: false)
            let first = try XCTUnwrap(controller.selectedTerminalTab)
            controller.openLocalTab()
            let second = try XCTUnwrap(controller.selectedTerminalTab)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let host = TerminalHostView(frame: .zero) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
                created[tab.id] = view
                return view
            }
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: first.id)
            XCTAssertTrue(created.isEmpty)
            host.setFrameSize(NSSize(width: 800, height: 480))
            XCTAssertEqual(created.count, 1)
            XCTAssertNil(created[second.id])
            let firstView = try XCTUnwrap(created[first.id])
            let firstFrame = firstView.frame
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: second.id)
            let secondView = try XCTUnwrap(created[second.id])
            host.setFrameSize(NSSize(width: 600, height: 360))
            XCTAssertEqual(firstView.frame, firstFrame)
            XCTAssertEqual(secondView.frame.size, NSSize(width: 600, height: 360))
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: first.id)
            XCTAssertEqual(firstView.frame.size, NSSize(width: 600, height: 360))

            controller.closeTab(second.id)
            host.synchronize(tabs: controller.terminalTabs, selectedTabID: first.id)
            XCTAssertNil(secondView.superview)
            XCTAssertEqual(host.subviews.count, 1)
        }
    }
}
