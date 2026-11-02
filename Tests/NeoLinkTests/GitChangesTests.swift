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
    func testGitActionsPreserveWorkingFilesAndOnlyCommitStagedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkGitActions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let result = try await CommandRunner.run("/usr/bin/git", ["-C", root.path] + args)
            guard result.status == 0 else { throw GitChanges.Failure.command(String(decoding: result.output, as: UTF8.self)) }
            return String(decoding: result.output, as: UTF8.self)
        }
        _ = try await git(["init", "-q"])
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await git(["config", key, value])
        }
        let path = "file [literal]\nname.txt", url = root.appendingPathComponent("file [literal]\nname.txt")
        try Data("original\n".utf8).write(to: url)
        var change = GitChange(path: path, originalPath: nil, index: "?", worktree: "?")
        try await GitChanges.stage(change, at: root)
        let currentSnapshot = try await GitChanges.snapshot(at: root)
        change = try XCTUnwrap(currentSnapshot.changes.first)
        try await GitChanges.unstage(change, at: root)
        XCTAssertEqual(try String(contentsOf: url), "original\n")
        let unstagedSnapshot = try await GitChanges.snapshot(at: root)
        XCTAssertTrue(unstagedSnapshot.changes.first?.untracked == true)
        try await GitChanges.stage(change, at: root)
        try await GitChanges.commit("First commit\n\nLiteral `text` and $(nothing)", at: root)
        let originalBranch = try await GitChanges.snapshot(at: root).branch
        try Data("staged\n".utf8).write(to: url)
        let changedSnapshot = try await GitChanges.snapshot(at: root)
        change = try XCTUnwrap(changedSnapshot.changes.first)
        try await GitChanges.stage(change, at: root)
        try Data("unstaged\n".utf8).write(to: url)
        try await GitChanges.commit("Only staged changes", at: root)
        let committed = try await git(["show", "HEAD:" + path])
        XCTAssertEqual(committed, "staged\n")
        XCTAssertEqual(try String(contentsOf: url), "unstaged\n")
        try await GitChanges.switchBranch("feature/test", create: true, at: root)
        let branchSnapshot = try await GitChanges.snapshot(at: root)
        XCTAssertEqual(branchSnapshot.branch, "feature/test")
        XCTAssertEqual(try String(contentsOf: url), "unstaged\n")
        _ = try await git(["stash", "push", "-m", "Preview stash"])
        let stashedSnapshot = try await GitChanges.snapshot(at: root)
        let stash = try XCTUnwrap(stashedSnapshot.stashes.first)
        let patch = try await GitChanges.stashDiff(stash, at: root)
        XCTAssertTrue(patch.contains("+unstaged"))
        try await GitChanges.switchBranch(originalBranch, at: root)
        do { try await GitChanges.switchBranch("--discard-changes", at: root); XCTFail("Accepted option as branch") } catch {}
        XCTAssertEqual(try String(contentsOf: url), "staged\n")
    }

    func testBranchSwitchRefusesConflictingWorkingChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkBranches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws {
            let result = try await CommandRunner.run("/usr/bin/git", ["-C", root.path] + args)
            XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
        }
        try await git(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { try await git(["config", key, value]) }
        let file = root.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: file)
        try await git(["add", "."]); try await git(["commit", "-qm", "Base"])
        try await GitChanges.switchBranch("other", create: true, at: root)
        try Data("other branch\n".utf8).write(to: file)
        try await git(["add", "."]); try await git(["commit", "-qm", "Other"])
        try await GitChanges.switchBranch("main", at: root)
        try Data("unsaved working file\n".utf8).write(to: file)
        do { try await GitChanges.switchBranch("other", at: root); XCTFail("Overwrote working changes") } catch {}
        XCTAssertEqual(try String(contentsOf: file), "unsaved working file\n")
    }

}
