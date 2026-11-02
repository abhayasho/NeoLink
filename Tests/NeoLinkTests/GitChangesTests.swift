import XCTest
@testable import NeoLink

final class GitChangesTests: XCTestCase {
    func testStatusPreservesWhitespaceAndRenameRecords() {
        let result = GitChanges.parseStatus(Data(" M odd [name]\nfile.txt\0R  renamed.txt\0old name.txt\0?? new file.py\0".utf8))
        XCTAssertEqual(result.map(\.path), ["odd [name]\nfile.txt", "renamed.txt", "new file.py"])
        XCTAssertEqual(result[1].originalPath, "old name.txt")
        XCTAssertTrue(result[1].staged)
        XCTAssertFalse(result[1].unstaged)
        XCTAssertTrue(result[2].untracked)
    }

    func testDiffsKeepStagedAndUnstagedChangesSeparateAndPathsLiteral() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws {
            let result = try await CommandRunner.run("/usr/bin/git", ["-C", root.path] + args)
            XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
        }
        try await git(["init", "-q"])
        let path = "file [literal].txt"
        let url = root.appendingPathComponent(path)
        try Data("original\n".utf8).write(to: url)
        try await git(["add", "--", path])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"])
        try Data("staged\n".utf8).write(to: url)
        try await git(["add", "--", path])
        try Data("working tree\n".utf8).write(to: url)
        try Data("new content\n".utf8).write(to: root.appendingPathComponent("new file.txt"))
        let snapshot = try await GitChanges.snapshot(at: root)
        let change = try XCTUnwrap(snapshot.changes.first { $0.path == path })
        XCTAssertTrue(change.staged && change.unstaged)
        let index = try await GitChanges.diff(change, at: root, staged: true)
        let worktree = try await GitChanges.diff(change, at: root, staged: false)
        XCTAssertTrue(index.contains("+staged")); XCTAssertFalse(index.contains("working tree"))
        XCTAssertTrue(worktree.contains("+working tree")); XCTAssertTrue(worktree.contains("-staged"))
        let newFile = try XCTUnwrap(snapshot.changes.first { $0.untracked })
        let preview = try await GitChanges.diff(newFile, at: root, staged: false)
        XCTAssertTrue(preview.contains("+new content"))
        XCTAssertEqual(try String(contentsOf: url), "working tree\n")
    }
}
