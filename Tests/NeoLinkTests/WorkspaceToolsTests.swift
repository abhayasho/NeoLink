import XCTest
@testable import NeoLink

final class WorkspaceToolsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCreationPreservesExistingFilesAndRejectsTraversal() async throws {
        let root = try directory()
        let operations = LocalFileOperations()
        let file = try await operations.create(named: "a 'quoted' file.py", in: root, isDirectory: false)
        try Data("valuable text".utf8).write(to: file)
        do { _ = try await operations.create(named: file.lastPathComponent, in: root, isDirectory: false); XCTFail("Overwrote a file") } catch {}
        XCTAssertEqual(try String(contentsOf: file), "valuable text")
        let folder = try await operations.create(named: "new folder", in: root, isDirectory: true)
        XCTAssertTrue(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        for name in ["..", ".", "../outside", "a/b", "", " \n", "a\0b"] {
            do { _ = try await operations.create(named: name, in: root, isDirectory: false); XCTFail("Accepted \(name)") } catch {}
        }
    }

    @MainActor
    func testProjectBookmarksSurviveFreshManagerWithoutDuplicates() throws {
        let root = try directory()
        let suite = "NeoLinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = WorkspaceAccess(defaults: defaults)
        try original.remember(root)
        try original.remember(root)
        let restored = WorkspaceAccess(defaults: defaults)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.recentFolders.count, 1)
        XCTAssertEqual(restored.projectURL?.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }

    func testProjectSearchExcludesDependenciesAndUsesLiteralQueries() async throws {
        guard CommandRunner.executable("rg") != nil else { throw XCTSkip("ripgrep is optional") }
        let root = try directory()
        for folder in ["src", "node_modules", ".git", ".venv", ".build", "dist"] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("first\nliteral.*needle\nlast\n".utf8).write(to: url.appendingPathComponent("a.swift"))
        }
        let files = try await ProjectSearch.files(in: root)
        XCTAssertEqual(files, ["src/a.swift"])
        let matches = try await ProjectSearch.matches(in: root, query: "literal.*needle")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.line, 2)
        XCTAssertEqual(matches.first?.path, "src/a.swift")
        let noRegexMatches = try await ProjectSearch.matches(in: root, query: "literal.+needle")
        XCTAssertTrue(noRegexMatches.isEmpty)
        XCTAssertEqual(ProjectSearch.filter(files, query: "src swift").count, 1)
    }

    func testCancellationStopsSearchProcessPromptly() async throws {
        let start = Date()
        let task = Task { try await CommandRunner.run("/bin/sleep", ["20"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should propagate") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCommandOutputIsBounded() async throws {
        let result = try await CommandRunner.run("/usr/bin/yes", [], maximumBytes: 1024)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.output.count, 1024)
    }
}
