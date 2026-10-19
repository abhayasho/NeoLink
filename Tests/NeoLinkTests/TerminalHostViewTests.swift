import AppKit
import SwiftTerm
import XCTest
@testable import NeoLink

final class TerminalHostViewTests: XCTestCase {
    func testTabRoundtripPreservesNativeScreenAndScrollbackAcrossZeroLayout() async throws {
        try await MainActor.run {
            let controller = TabsController()
            let first = try XCTUnwrap(controller.selectedTab)
            controller.openLocalTab()
            let second = try XCTUnwrap(controller.selectedTab)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let size = NSSize(width: 800, height: 480)
            let host = TerminalHostView(frame: NSRect(origin: .zero, size: size)) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
                created[tab.id] = view
                return view
            }
            host.synchronize(tabs: controller.tabs, selectedTabID: first.id)
            let firstView = try XCTUnwrap(created[first.id])
            firstView.feed(text: (0..<70).map { "SCROLLBACK_LINE_\($0)\r\n" }.joined() + "VISIBLE_MARKER\r\n")
            let before = firstView.terminal.getBufferAsData(kind: .normal)
            let columns = firstView.terminal.cols
            let rows = firstView.terminal.rows
            XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("VISIBLE_MARKER"))
            XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("SCROLLBACK_LINE_0"))

            host.synchronize(tabs: controller.tabs, selectedTabID: second.id)
            XCTAssertTrue(firstView.isHidden)
            XCTAssertTrue(firstView.superview === host)
            host.setFrameSize(.zero)
            XCTAssertEqual(firstView.terminal.cols, columns)
            XCTAssertEqual(firstView.terminal.rows, rows)
            host.setFrameSize(size)
            host.synchronize(tabs: controller.tabs, selectedTabID: first.id)

            XCTAssertFalse(firstView.isHidden)
            XCTAssertTrue(created[first.id] === firstView)
            XCTAssertEqual(firstView.terminal.getBufferAsData(kind: .normal), before)
            XCTAssertEqual(firstView.terminal.cols, columns)
            XCTAssertEqual(firstView.terminal.rows, rows)
            XCTAssertEqual(created.count, 2)
        }
    }

    func testHostLaunchesOnlySelectedTabsAndKeepsHiddenFrameUntilSelected() async throws {
        try await MainActor.run {
            let controller = TabsController()
            let first = try XCTUnwrap(controller.selectedTab)
            controller.openLocalTab()
            let second = try XCTUnwrap(controller.selectedTab)
            var created: [UUID: LocalProcessTerminalView] = [:]
            let host = TerminalHostView(frame: .zero) { tab, size in
                let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
                created[tab.id] = view
                return view
            }
            host.synchronize(tabs: controller.tabs, selectedTabID: first.id)
            XCTAssertTrue(created.isEmpty)
            host.setFrameSize(NSSize(width: 800, height: 480))
            XCTAssertEqual(created.count, 1)
            XCTAssertNil(created[second.id])
            let firstView = try XCTUnwrap(created[first.id])
            let firstFrame = firstView.frame
            host.synchronize(tabs: controller.tabs, selectedTabID: second.id)
            let secondView = try XCTUnwrap(created[second.id])
            host.setFrameSize(NSSize(width: 600, height: 360))
            XCTAssertEqual(firstView.frame, firstFrame)
            XCTAssertEqual(secondView.frame.size, NSSize(width: 600, height: 360))
            host.synchronize(tabs: controller.tabs, selectedTabID: first.id)
            XCTAssertEqual(firstView.frame.size, NSSize(width: 600, height: 360))

            controller.closeTab(second.id)
            host.synchronize(tabs: controller.tabs, selectedTabID: first.id)
            XCTAssertNil(secondView.superview)
            XCTAssertEqual(host.subviews.count, 1)
        }
    }
}
