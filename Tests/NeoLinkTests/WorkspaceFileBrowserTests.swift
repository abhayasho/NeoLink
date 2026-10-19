import XCTest
@testable import NeoLink

final class WorkspaceFileBrowserTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testReturningToTabPreservesManualDirectoryFilterAndFollowPreference() throws {
        let directory = try temporaryDirectory()
        let manualDirectory = directory.appendingPathComponent("manual", isDirectory: true)
        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: manualDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: false)
        let first = TerminalTab(title: "First", configuration: TerminalConfiguration(backend: .localShell), currentDirectory: directory.path)
        let second = TerminalTab(title: "Second", configuration: TerminalConfiguration(backend: .localShell), currentDirectory: otherDirectory.path)
        let browsers = WorkspaceFileBrowsers()
        let firstBrowser = browsers.browser(for: first)
        firstBrowser.navigate(to: manualDirectory)
        firstBrowser.searchText = "notes"
        firstBrowser.sortOrder = .dateModifiedNewest

        let secondBrowser = browsers.browser(for: second)
        secondBrowser.searchText = "readme"
        let returnedBrowser = browsers.browser(for: first)
        // FileBrowserPane synchronizes again when the observed terminal changes.
        returnedBrowser.syncTo(path: first.state.currentDirectory ?? "")

        XCTAssertTrue(returnedBrowser === firstBrowser)
        XCTAssertFalse(returnedBrowser === secondBrowser)
        XCTAssertEqual(returnedBrowser.currentURL, manualDirectory.standardizedFileURL)
        XCTAssertEqual(returnedBrowser.searchText, "notes")
        XCTAssertEqual(returnedBrowser.sortOrder, .dateModifiedNewest)
        XCTAssertFalse(returnedBrowser.followsTerminal)
        XCTAssertEqual(secondBrowser.currentURL, otherDirectory.standardizedFileURL)
        XCTAssertEqual(secondBrowser.searchText, "readme")
        XCTAssertTrue(secondBrowser.followsTerminal)
    }

    @MainActor
    func testRetainTabsPreservesOpenBrowserAndDiscardsClosedBrowserState() throws {
        let directory = try temporaryDirectory()
        let closed = TerminalTab(title: "Closed", configuration: TerminalConfiguration(backend: .localShell), currentDirectory: directory.path)
        let open = TerminalTab(title: "Open", configuration: TerminalConfiguration(backend: .localShell), currentDirectory: directory.path)
        let browsers = WorkspaceFileBrowsers()
        let closedBrowser = browsers.browser(for: closed)
        closedBrowser.searchText = "old filter"
        closedBrowser.setFollowTerminal(false)
        let openBrowser = browsers.browser(for: open)
        openBrowser.searchText = "retained filter"

        browsers.retainTabs([open.id])

        XCTAssertTrue(browsers.browser(for: open) === openBrowser)
        XCTAssertEqual(browsers.browser(for: open).searchText, "retained filter")
        let freshBrowser = browsers.browser(for: closed)
        XCTAssertFalse(freshBrowser === closedBrowser)
        XCTAssertEqual(freshBrowser.searchText, "")
        XCTAssertTrue(freshBrowser.followsTerminal)
    }

    @MainActor
    func testPruningAllTabsReleasesTheirBrowsersEvenWithLoadsInFlight() throws {
        let directory = try temporaryDirectory()
        let tab = TerminalTab(title: "Local", configuration: TerminalConfiguration(backend: .localShell), currentDirectory: directory.path)
        let browsers = WorkspaceFileBrowsers()
        weak var browser: LocalFileBrowserViewModel?
        do {
            let retained = browsers.browser(for: tab)
            browser = retained
        }
        XCTAssertNotNil(browser)

        browsers.retainTabs([])

        XCTAssertNil(browser)
    }
}
