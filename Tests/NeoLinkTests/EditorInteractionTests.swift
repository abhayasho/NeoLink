import XCTest
@testable import NeoLink

final class EditorInteractionTests: XCTestCase {
    func testPreciseScrollingAccumulatesFractionsAndKeepsAxesSeparate() {
        var wheel = WheelScrollAccumulator()
        let cell = CGSize(width: 8, height: 20)
        for _ in 0..<3 {
            XCTAssertEqual(wheel.consume(x: 0, y: -5, precise: true, cell: cell, newGesture: false).y, 0)
        }
        XCTAssertEqual(wheel.consume(x: 8, y: -5, precise: true, cell: cell, newGesture: false).y, -1)
        let next = wheel.consume(x: -16, y: 40, precise: true, cell: cell, newGesture: false)
        XCTAssertEqual(next.x, -2); XCTAssertEqual(next.y, 2)
        XCTAssertEqual(wheel.consume(x: 0, y: 0.5, precise: false, cell: cell, newGesture: false).y, 0)
        XCTAssertEqual(wheel.consume(x: 0, y: 0.5, precise: false, cell: cell, newGesture: true).y, 0)
        XCTAssertEqual(wheel.consume(x: 0, y: 500, precise: false, cell: cell, newGesture: false).y, 80)
    }

    @MainActor
    func testTextSizePersistsAndHasSafeBounds() throws {
        let suite = "NeoLinkZoomTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = TextSizePreferences(defaults: defaults)
        XCTAssertEqual(size.pointSize, 13)
        size.adjust(by: 3)
        XCTAssertEqual(TextSizePreferences(defaults: defaults).pointSize, 16)
        size.set(100); XCTAssertEqual(size.pointSize, 32)
        size.set(-10); XCTAssertEqual(size.pointSize, 9)
        size.set(.infinity); XCTAssertEqual(size.pointSize, 13)
        size.set(18); size.reset()
        XCTAssertEqual(TextSizePreferences(defaults: defaults).pointSize, 13)
    }

    @MainActor
    func testDockedAgentsKeepEditorSelectionAndSurvivePanelHiding() throws {
        let controller = TabsController(useNeovim: false)
        let original = try XCTUnwrap(controller.selectedTabID)
        let folder = FileManager.default.temporaryDirectory
        try controller.openAgent(.claude(), in: folder)
        let first = try XCTUnwrap(controller.agentPanelTabs.first)
        XCTAssertEqual(controller.selectedTabID, original)
        XCTAssertEqual(controller.agentPanelTabID, first.id)
        XCTAssertFalse(controller.workspaceTabs.contains { $0.id == first.id })
        XCTAssertFalse(first.state.hasStarted)
        controller.showAgentPanel = false
        XCTAssertFalse(first.state.isClosed)
        try controller.openAgent(.claude(continueSession: true), in: folder)
        XCTAssertTrue(controller.showAgentPanel)
        XCTAssertEqual(controller.agentPanelTabs.count, 2)
        controller.closeTab(try XCTUnwrap(controller.agentPanelTabID))
        XCTAssertEqual(controller.agentPanelTabID, first.id)
        controller.closeTab(original)
        XCTAssertEqual(controller.workspaceTabs.count, 1)
        XCTAssertNotEqual(controller.selectedTabID, first.id)
        XCTAssertEqual(controller.agentPanelTabs.count, 1)
        controller.closeTab(first.id)
        XCTAssertTrue(first.state.isClosed)
        XCTAssertNil(controller.agentPanelTabID)
    }

    @MainActor
    func testREPLUsesChosenProjectWithoutLaunchingUntilViewed() throws {
        let controller = TabsController(useNeovim: false)
        let folder = URL(fileURLWithPath: "/tmp/a 'quoted' project")
        controller.openREPL("python3", in: folder)
        let tab = try XCTUnwrap(controller.selectedTerminalTab)
        XCTAssertEqual(tab.title, "python3 REPL")
        XCTAssertEqual(tab.state.currentDirectory, folder.path)
        XCTAssertFalse(tab.state.hasStarted)
        XCTAssertNil(tab.agentName)
        XCTAssertTrue(tab.configuration.startupCommand?.contains("'\\''") == true)
        controller.openREPL("unrecognized", in: folder)
        XCTAssertEqual(controller.tabs.count, 2)
    }
}
