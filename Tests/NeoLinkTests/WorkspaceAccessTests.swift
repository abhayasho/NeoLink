import XCTest
@testable import NeoLink

final class WorkspaceAccessTests: XCTestCase {
    private enum Unavailable: Error { case folder }

    private func defaults() throws -> UserDefaults {
        let suite = "NeoLinkBookmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func operations(
        resolve: @escaping (Data) throws -> (url: URL, stale: Bool),
        create: @escaping (URL) throws -> Data = { Data($0.path.utf8) },
        start: @escaping (URL) -> Bool = { _ in true },
        stop: @escaping (URL) -> Void = { _ in }
    ) -> FolderBookmarkOperations {
        FolderBookmarkOperations(resolve: resolve, create: create, startAccess: start, stopAccess: stop)
    }

    @MainActor
    func testUnavailableBookmarkSurvivesLaunchAndAddingAnotherFolder() throws {
        let defaults = try defaults()
        let missing = Data("offline grant".utf8)
        let available = URL(fileURLWithPath: "/tmp/available-project")
        defaults.set([missing], forKey: "workspaceFolderBookmarks")
        defaults.set("/tmp/offline-project", forKey: "activeProjectPath")

        let first = WorkspaceAccess(defaults: defaults, operations: operations(resolve: { _ in throw Unavailable.folder }))
        XCTAssertNil(first.error, "An unused offline folder must not cause a launch alert")
        XCTAssertNil(first.projectURL)
        try first.remember(available)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [Data(available.path.utf8), missing])

        let recovered = URL(fileURLWithPath: "/tmp/offline-project")
        let second = WorkspaceAccess(defaults: defaults, operations: operations(resolve: { data in
            (data == missing ? recovered : available, false)
        }))
        XCTAssertEqual(second.recentFolders, [available, recovered])
        XCTAssertEqual(second.projectURL, available)
        try second.remember(available)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [Data(available.path.utf8), missing])
    }

    @MainActor
    func testStaleBookmarkSurvivesFailedRenewalThenRefreshes() throws {
        let defaults = try defaults()
        let original = Data("old grant".utf8)
        let refreshed = Data("renewed grant".utf8)
        let url = URL(fileURLWithPath: "/tmp/saved-project")
        defaults.set([original], forKey: "workspaceFolderBookmarks")
        defaults.set(url.path, forKey: "activeProjectPath")
        let first = WorkspaceAccess(defaults: defaults, operations: operations(
            resolve: { _ in (url, true) }, create: { _ in throw Unavailable.folder }))
        XCTAssertEqual(first.projectURL, url)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [original])
        let second = WorkspaceAccess(defaults: defaults, operations: operations(
            resolve: { _ in (url, true) }, create: { _ in refreshed }))
        XCTAssertEqual(second.projectURL, url)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [refreshed])
    }

    @MainActor
    func testOnlySelectedFoldersActivateAccessAndEachScopeIsBalanced() throws {
        let defaults = try defaults()
        let first = URL(fileURLWithPath: "/tmp/first-project")
        let second = URL(fileURLWithPath: "/tmp/second-project")
        defaults.set([Data(first.path.utf8), Data(second.path.utf8)], forKey: "workspaceFolderBookmarks")
        defaults.set(first.path, forKey: "activeProjectPath")
        var started: [URL] = []
        var stopped: [URL] = []
        var access: WorkspaceAccess? = WorkspaceAccess(defaults: defaults, operations: operations(
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { started.append($0); return true }, stop: { stopped.append($0) }))
        XCTAssertEqual(started, [first])
        access?.select(second)
        access?.select(first)
        try access?.remember(second)
        XCTAssertEqual(started, [first, second])
        access = nil
        XCTAssertEqual(stopped, [first, second])
    }
}
