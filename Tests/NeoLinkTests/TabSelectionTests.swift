import Combine
import XCTest
@testable import NeoLink

/// The selected tab is published apart from `TabsController`, so a tab switch does not invalidate every view that
/// observes the controller (the workspace root and its layout). What those views do need from a switch, the file
/// browser to follow a different terminal, is published by `browserTabID` only when it changes.
@MainActor
final class TabSelectionTests: XCTestCase {
    func testSwitchingDocumentsPublishesTheSelectionButNotTheController() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabSelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)

        let controller = TabsController(useNeovim: false)
        let terminal = try XCTUnwrap(controller.selectedTerminalTab)
        XCTAssertEqual(controller.browserTabID, terminal.id)
        controller.openFile(a)
        let first = try XCTUnwrap(controller.selectedTab?.document)
        controller.openFile(b)
        let second = try XCTUnwrap(controller.selectedTab?.document)
        XCTAssertEqual(controller.browserTabID, terminal.id, "documents opened beside a terminal keep its browser")

        var controllerChanges = 0, selectionChanges = 0
        let observers: [AnyCancellable] = [controller.objectWillChange.sink { controllerChanges += 1 },
                                           controller.selection.objectWillChange.sink { selectionChanges += 1 }]
        defer { observers.forEach { $0.cancel() } }
        controller.selectedTabID = first.id
        controller.selectedTabID = second.id
        controller.selectedTabID = second.id   // unchanged: nothing is published
        XCTAssertEqual(selectionChanges, 2)
        XCTAssertEqual(controllerChanges, 0, "switching between documents of one browser does not invalidate the workspace root")
        XCTAssertEqual(controller.selectedTab?.document?.id, second.id)

        // A switch that changes which browser is shown does publish it.
        controller.openLocalTab()
        let other = try XCTUnwrap(controller.selectedTerminalTab)
        XCTAssertEqual(controller.browserTabID, other.id)
        controllerChanges = 0
        controller.selectedTabID = first.id
        XCTAssertEqual(controller.browserTabID, terminal.id)
        XCTAssertGreaterThan(controllerChanges, 0)
        controllerChanges = 0
        controller.selectedTabID = other.id
        XCTAssertEqual(controller.browserTabID, other.id)
        XCTAssertGreaterThan(controllerChanges, 0)

        // Closing the selected terminal falls back to a neighbour, and the browser follows.
        controller.closeTab(other.id)
        XCTAssertEqual(controller.browserTabID, controller.browserTab?.id)
        XCTAssertNotEqual(controller.browserTabID, other.id)
    }
}
