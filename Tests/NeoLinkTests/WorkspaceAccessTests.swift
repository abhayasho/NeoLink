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

    @MainActor
    func testForgetOneProjectPersistsWithoutDeletingItsFilesOrOtherBookmarks() throws {
        let defaults = try defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keep.txt")
        try Data("keep this file".utf8).write(to: file)
        let other = URL(fileURLWithPath: "/tmp/other-project")
        let unavailable = Data("offline grant".utf8)
        let resolver = operations(resolve: { data in
            if data == unavailable { throw Unavailable.folder }
            return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        })
        defaults.set([Data(directory.path.utf8), Data(other.path.utf8), unavailable], forKey: "workspaceFolderBookmarks")
        defaults.set(other.path, forKey: "activeProjectPath")
        let access = WorkspaceAccess(defaults: defaults, operations: resolver)
        access.forget(directory.appendingPathComponent("."))
        access.forget(directory) // Repeated removal is harmless.
        let restored = WorkspaceAccess(defaults: defaults, operations: resolver)
        XCTAssertEqual(restored.recentFolders, [other])
        XCTAssertEqual(restored.projectURL, other)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [Data(other.path.utf8), unavailable])
        XCTAssertEqual(try String(contentsOf: file), "keep this file")
    }

    @MainActor
    func testForgettingActiveProjectKeepsItsLiveScopeUntilShutdown() throws {
        let defaults = try defaults()
        let folder = URL(fileURLWithPath: "/tmp/current-project")
        defaults.set([Data(folder.path.utf8)], forKey: "workspaceFolderBookmarks")
        defaults.set(folder.path, forKey: "activeProjectPath")
        var stopped: [URL] = []
        let resolver = operations(resolve: { _ in (folder, false) }, stop: { stopped.append($0) })
        var access: WorkspaceAccess? = WorkspaceAccess(defaults: defaults, operations: resolver)
        access?.forget(folder)
        XCTAssertEqual(access?.projectURL, folder, "Forgetting a shortcut must not close the current workspace")
        XCTAssertEqual(access?.hasSavedFolders, false)
        XCTAssertTrue(stopped.isEmpty, "Open terminals and editors may still need the active grant")
        XCTAssertNil(defaults.string(forKey: "activeProjectPath"))
        let restored = WorkspaceAccess(defaults: defaults, operations: resolver)
        XCTAssertNil(restored.projectURL)
        XCTAssertTrue(restored.recentFolders.isEmpty)
        access = nil
        XCTAssertEqual(stopped, [folder])
    }

    @MainActor
    func testClearRecentProjectsAlsoForgetsUnavailableFoldersAcrossLaunches() throws {
        let defaults = try defaults()
        let folder = URL(fileURLWithPath: "/tmp/current-project")
        let unavailable = Data("offline grant".utf8)
        defaults.set([Data(folder.path.utf8), unavailable], forKey: "workspaceFolderBookmarks")
        defaults.set(folder.path, forKey: "activeProjectPath")
        var stopped: [URL] = []
        let resolver = operations(resolve: { data in
            if data == unavailable { throw Unavailable.folder }
            return (folder, false)
        }, stop: { stopped.append($0) })
        let access = WorkspaceAccess(defaults: defaults, operations: resolver)
        access.clearRecentFolders()
        access.clearRecentFolders()
        XCTAssertEqual(access.projectURL, folder)
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertFalse(access.hasSavedFolders)
        XCTAssertEqual(defaults.array(forKey: "workspaceFolderBookmarks") as? [Data], [])
        let restored = WorkspaceAccess(defaults: defaults, operations: resolver)
        XCTAssertNil(restored.projectURL)
        XCTAssertTrue(restored.recentFolders.isEmpty)
        XCTAssertFalse(restored.hasSavedFolders)
    }
}
