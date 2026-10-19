import XCTest
@testable import NeoLink

final class TerminalTabsTests: XCTestCase {
    func testOSCWorkingDirectoryURLsBecomeDecodedFilePaths() {
        XCTAssertEqual(TerminalState.directoryPath(from: "file://localhost/Users/test/My%20Project"), "/Users/test/My Project")
        XCTAssertEqual(TerminalState.directoryPath(from: "file://remote/home/test/caf%C3%A9"), "/home/test/café")
        XCTAssertEqual(TerminalState.directoryPath(from: "/tmp/already a path"), "/tmp/already a path")
        XCTAssertNil(TerminalState.directoryPath(from: nil))
        XCTAssertNil(TerminalState.directoryPath(from: "https://example.com/path"))
    }

    func testSwitchingTabsKeepsSeparateDirectoryTitleAndPendingCommands() throws {
        let controller = TabsController()
        let first = try XCTUnwrap(controller.selectedTab)
        first.state.currentDirectory = "/tmp/first"
        first.state.terminalTitle = "First shell"
        first.state.pendingCommand = "echo first\n"

        controller.openTab(title: "Remote", configuration: TerminalConfiguration(backend: .ssh(host: "example.com", username: "test", port: 22)))
        let second = try XCTUnwrap(controller.selectedTab)
        second.state.currentDirectory = "/home/test"
        second.state.terminalTitle = "test@example.com"
        second.state.pendingCommand = "echo second\n"
        XCTAssertFalse(first.state === second.state)

        controller.selectedTabID = first.id
        XCTAssertTrue(controller.selectedTab?.state === first.state)
        XCTAssertEqual(controller.selectedTab?.state.currentDirectory, "/tmp/first")
        XCTAssertEqual(controller.selectedTab?.state.terminalTitle, "First shell")
        XCTAssertEqual(controller.selectedTab?.state.pendingCommand, "echo first\n")
        XCTAssertEqual(second.state.pendingCommand, "echo second\n")
    }

    func testOpeningAndSwitchingTabsDoesNotStartTheirProcesses() throws {
        let controller = TabsController()
        let first = try XCTUnwrap(controller.selectedTab)
        controller.openLocalTab()
        let second = try XCTUnwrap(controller.selectedTab)
        controller.selectedTabID = first.id
        XCTAssertFalse(first.state.hasStarted)
        XCTAssertFalse(second.state.hasStarted)
        XCTAssertEqual(first.state.processStatus, .idle)
        XCTAssertEqual(second.state.processStatus, .idle)
    }

    func testClosingSelectedTabChoosesNeighborAndDisposesState() throws {
        let controller = TabsController()
        let first = try XCTUnwrap(controller.selectedTab)
        controller.openLocalTab()
        let middle = try XCTUnwrap(controller.selectedTab)
        controller.openLocalTab()
        let last = try XCTUnwrap(controller.selectedTab)
        controller.selectedTabID = middle.id
        middle.state.pendingCommand = "echo pending\n"

        controller.closeTab(middle.id)
        XCTAssertEqual(controller.selectedTabID, last.id)
        XCTAssertTrue(middle.state.isClosed)
        XCTAssertNil(middle.state.pendingCommand)
        XCTAssertFalse(first.state.isClosed)
        XCTAssertFalse(last.state.isClosed)
        XCTAssertEqual(controller.tabs.count, 2)
    }

    func testClosingLastTabCreatesFreshLocalTab() throws {
        let controller = TabsController()
        let old = try XCTUnwrap(controller.selectedTab)
        controller.closeTab(old.id)
        let replacement = try XCTUnwrap(controller.selectedTab)
        XCTAssertEqual(controller.tabs.count, 1)
        XCTAssertNotEqual(replacement.id, old.id)
        XCTAssertEqual(replacement.configuration.backend, .localShell)
        XCTAssertTrue(old.state.isClosed)
        XCTAssertFalse(replacement.state.hasStarted)
    }

    func testClosingBackgroundTabDoesNotChangeSelection() throws {
        let controller = TabsController()
        let first = try XCTUnwrap(controller.selectedTab)
        controller.openLocalTab()
        let selected = try XCTUnwrap(controller.selectedTab)
        controller.closeTab(first.id)
        XCTAssertEqual(controller.selectedTabID, selected.id)
        XCTAssertFalse(selected.state.isClosed)
    }

    func testTabNavigationWrapsInBothDirections() throws {
        let controller = TabsController()
        let first = try XCTUnwrap(controller.selectedTab)
        controller.openLocalTab()
        let last = try XCTUnwrap(controller.selectedTab)
        controller.selectNextTab()
        XCTAssertEqual(controller.selectedTabID, first.id)
        controller.selectPreviousTab()
        XCTAssertEqual(controller.selectedTabID, last.id)
    }
}
