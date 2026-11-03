import XCTest
import Combine
@testable import NeoLink

final class ExplorerTests: XCTestCase {
    @MainActor
    func testRefreshKeepsVisibleRowsAndDoesNotRepeatEditorReveal() async throws {
        let root = try directory()
        try write("src/main.swift", in: root)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: false, compact: true, hideIgnored: false)
        try await wait { !tree.isLoading }
        let file = root.appendingPathComponent("src/main.swift")
        tree.reveal(file)
        try await wait { !tree.isLoading && tree.rowID(for: file) != nil }
        let reveal = tree.revealRevision, revision = tree.rowsRevision
        var snapshots: [[ExplorerRow]] = []
        let observation = tree.$rows.sink { snapshots.append($0) }
        defer { observation.cancel() }
        tree.reload()
        XCTAssertTrue(tree.rows.contains { $0.item.url == file })
        try await wait { !tree.isLoading }
        XCTAssertTrue(snapshots.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(tree.revealRevision, reveal)
        XCTAssertEqual(tree.rowsRevision, revision, "Unchanged refresh must not republish the row model")
        try write("src/added.swift", in: root)
        tree.reload()
        try await wait { !tree.isLoading && tree.rows.contains { $0.name == "added.swift" } }
        XCTAssertTrue(snapshots.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(tree.revealRevision, reveal)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-explorer-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ path: String, in root: URL, text: String = "content") throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() {
            if Date() > deadline { XCTFail("Explorer did not settle"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor
    func testLazyExpansionCompactsChainsAndRevealDoesNotReadSiblings() async throws {
        let root = try directory()
        try write("src/main/java/App.java", in: root)
        try write("dependencies/deep/untouched.js", in: root)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: true, compact: true, hideIgnored: false)
        try await wait { !tree.isLoading }
        XCTAssertEqual(Set(tree.children.keys.map(\.path)), [root.path])
        let src = try XCTUnwrap(tree.rows.first { $0.name == "src" })
        tree.toggle(src)
        try await wait { !tree.isLoading }
        XCTAssertTrue(tree.rows.contains { $0.name == "src/main/java" && $0.expanded })
        XCTAssertTrue(tree.rows.contains { $0.name == "App.java" })
        XCTAssertNil(tree.children[root.appendingPathComponent("dependencies")])
        tree.collapseAll()
        try await wait { !tree.isLoading }
        XCTAssertFalse(tree.rows.contains { $0.name == "App.java" })
        let file = root.appendingPathComponent("src/main/java/App.java")
        tree.reveal(file)
        try await wait { tree.rowID(for: file) != nil }
        XCTAssertEqual(tree.selectedURL, file)
        tree.setDiagnostics([file.path: ExplorerDiagnostics(errors: 2, warnings: 1)])
        try await wait { !tree.isLoading }
        XCTAssertEqual(tree.rows.first { $0.name == "src/main/java" }?.diagnostics.count, 3)
        XCTAssertEqual(tree.rows.first { $0.name == "App.java" }?.diagnostics.errors, 2)
        let revision = tree.revealRevision
        tree.setFilter("App")
        XCTAssertEqual(tree.revealRevision, revision, "Filtering must not repeatedly scroll the viewport")
        tree.reveal(root.deletingLastPathComponent().appendingPathComponent("outside.swift"))
        XCTAssertEqual(tree.selectedURL, file, "An unrelated active file must not replace the browser root")
    }
    @MainActor
    func testLatestRootWinsAndCompactModeCanBeDisabled() async throws {
        let root = try directory(), other = try directory()
        try write("a/b/c.swift", in: root)
        try write("latest.txt", in: other)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: false, compact: true, hideIgnored: false)
        tree.configure(root: other, hidden: false, compact: false, hideIgnored: false)
        try await wait { !tree.isLoading }
        XCTAssertEqual(tree.rows.map(\.name), ["latest.txt"])
        tree.configure(root: root, hidden: false, compact: false, hideIgnored: false)
        try await wait { !tree.isLoading }
        tree.toggle(try XCTUnwrap(tree.rows.first))
        try await wait { !tree.isLoading }
        XCTAssertEqual(tree.rows.map(\.name), ["a", "b"])
        XCTAssertNil(tree.children[root.appendingPathComponent("a/b")])
    }
    @MainActor
    func testCompactionDoesNotFollowSymlinkCycles() async throws {
        let root = try directory()
        let child = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: child)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: true, compact: true, hideIgnored: false)
        try await wait { !tree.isLoading }
        tree.toggle(try XCTUnwrap(tree.rows.first))
        try await wait { !tree.isLoading }
        XCTAssertEqual(tree.rows.map(\.name), ["src", "loop"])
        XCTAssertTrue(tree.rows.last?.item.isSymbolicLink == true)
        XCTAssertEqual(tree.children.count, 2)
    }
    @MainActor
    func testGitDecorationsRespectIgnoreRulesAndDeletedEntries() async throws {
        let root = try directory()
        func git(_ args: [String]) async throws {
            let result = try await CommandRunner.run("/usr/bin/git", ["-C", root.path] + args)
            XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
        }
        try await git(["init", "-q"])
        for name in ["modified.swift", "deleted.py", "nested/gone.txt", "tracked.log", "quoted\nname.swift"] { try write(name, in: root) }
        try await git(["add", "."])
        try await git(["-c", "user.name=Explorer Test", "-c", "user.email=explorer@example.invalid", "commit", "-qm", "Initial files"])
        try write(".gitignore", in: root, text: "cache/\n*.log\n!keep.log\n")
        try write("cache/deep/ignored.js", in: root)
        try write("keep.log", in: root)
        try write("tracked.log", in: root, text: "changed tracked file")
        try write("modified.swift", in: root, text: "changed")
        try write("quoted\nname.swift", in: root, text: "changed")
        try write("added.ts", in: root)
        try await git(["add", "added.ts"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.py"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("nested"))
        let snapshot = try await ExplorerGitSnapshot.load(at: root)
        let state = try XCTUnwrap(snapshot)
        XCTAssertEqual(state.state(for: root.appendingPathComponent("modified.swift"), directory: false), .modified)
        XCTAssertEqual(state.states["quoted\nname.swift"], .modified)
        XCTAssertEqual(state.states["added.ts"], .added)
        XCTAssertEqual(state.states["deleted.py"], .deleted)
        XCTAssertEqual(state.states["keep.log"], .untracked)
        XCTAssertEqual(state.states["tracked.log"], .modified)
        XCTAssertEqual(state.state(for: root.appendingPathComponent("cache/deep/ignored.js"), directory: false), .ignored)
        XCTAssertNil(state.states["cache/deep/ignored.js"], "Ignored trees must not be enumerated by status")
        XCTAssertTrue(state.deletedChildren(in: root).contains { $0.url.lastPathComponent == "deleted.py" && !$0.isDirectory })
        XCTAssertTrue(state.deletedChildren(in: root).contains { $0.url.lastPathComponent == "nested" && $0.isDirectory })
        XCTAssertEqual(state.state(for: root.appendingPathComponent("nested"), directory: true), .deleted)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: false, compact: true, hideIgnored: false)
        try await wait { !tree.isLoading && tree.git != nil }
        XCTAssertTrue(tree.rows.contains { $0.name == "cache" && $0.git == .ignored })
        XCTAssertTrue(tree.rows.contains { $0.name == "deleted.py" && $0.missing })
        tree.toggle(try XCTUnwrap(tree.rows.first { $0.name == "nested" }))
        try await wait { !tree.isLoading }
        XCTAssertTrue(tree.rows.contains { $0.name == "gone.txt" && $0.missing })
        tree.configure(root: root, hidden: false, compact: true, hideIgnored: true)
        try await wait { !tree.isLoading }
        XCTAssertFalse(tree.rows.contains { $0.name == "cache" })
        XCTAssertNil(tree.children[root.appendingPathComponent("cache").standardizedFileURL])
    }
    @MainActor
    func testRevealCanShowActiveDotfileWithoutShowingOtherHiddenFiles() async throws {
        let root = try directory()
        try write(".config/tool.toml", in: root)
        try write(".other", in: root)
        let tree = ExplorerTree()
        tree.configure(root: root, hidden: false, compact: true, hideIgnored: false)
        try await wait { !tree.isLoading }
        XCTAssertTrue(tree.rows.isEmpty)
        let file = root.appendingPathComponent(".config/tool.toml")
        tree.reveal(file)
        try await wait { !tree.isLoading && tree.rowID(for: file) != nil }
        XCTAssertFalse(tree.rows.contains { $0.name == ".other" })
        XCTAssertTrue(tree.rows.contains { $0.name == "tool.toml" })
    }
    func testFuzzyQuickOpenRanksFilenameAndSupportsSparsePaths() {
        let files = ["docs/ProjectSearch.md", "Sources/Workspace/ProjectSearch.swift", "ProjectSearch.swift", "Sources/Tabs/TabsController.swift"]
        XCTAssertEqual(ProjectSearch.filter(files, query: "prjsrch").count, 3)
        XCTAssertEqual(ProjectSearch.filter(files, query: "ProjectSearch.swift").first?.path, "ProjectSearch.swift")
        XCTAssertEqual(ProjectSearch.filter(files, query: "swpjsw").first?.path, "Sources/Workspace/ProjectSearch.swift")
        XCTAssertTrue(ProjectSearch.filter(files, query: "zzzz").isEmpty)
    }
    @MainActor
    func testTerminalHookUsesFolderAndStartsOnlyWhenViewed() throws {
        let tabs = TabsController(useNeovim: false)
        let folder = URL(fileURLWithPath: "/tmp/project 'with quotes'")
        tabs.openTerminal(in: folder)
        let tab = try XCTUnwrap(tabs.selectedTerminalTab)
        XCTAssertEqual(tab.state.currentDirectory, folder.path)
        XCTAssertNil(tab.configuration.startupCommand)
        XCTAssertFalse(tab.state.hasStarted)
    }
}
