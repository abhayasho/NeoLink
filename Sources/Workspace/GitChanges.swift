import Foundation

struct GitChange: Identifiable, Equatable {
    let path: String
    let originalPath: String?
    let index: Character
    let worktree: Character
    var id: String { path }
    var untracked: Bool { index == "?" }
    var staged: Bool { index != " " && index != "?" }
    var unstaged: Bool { worktree != " " }
}

enum GitChanges {
    struct Snapshot { let root: URL; let branch: String; let changes: [GitChange]; var branches: [String] = []; var stashes: [Stash] = [] }
    struct Stash: Identifiable { let id: String; let title: String }
    enum Failure: LocalizedError {
        case command(String), tooLarge
        var errorDescription: String? {
            switch self {
            case .command(let message): return message
            case .tooLarge: return "This Git result exceeds the preview limit. Review it in a terminal."
            }
        }
    }

    static func parseStatus(_ data: Data) -> [GitChange] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var result: [GitChange] = [], i = 0
        while i < records.count {
            let bytes = Array(records[i]); i += 1
            guard bytes.count >= 4, bytes[2] == 32 else { continue }
            let index = Character(UnicodeScalar(bytes[0]))
            let worktree = Character(UnicodeScalar(bytes[1]))
            let path = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            var original: String?
            if [index, worktree].contains("R") || [index, worktree].contains("C") {
                guard i < records.count else { break }
                original = String(decoding: records[i], as: UTF8.self); i += 1
            }
            result.append(GitChange(path: path, originalPath: original, index: index, worktree: worktree))
        }
        return result
    }

    private static func run(_ args: [String], at directory: URL, acceptsDifference: Bool = false) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--no-pager", "--literal-pathspecs", "-C", directory.path] + args,
                                                 timeout: 120, maximumBytes: 1024 * 1024)
        guard !result.truncated else { throw Failure.tooLarge }
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0 || (acceptsDifference && result.status == 1) else {
            throw Failure.command(output.isEmpty ? "Git failed with exit code \(result.status)." : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    static func snapshot(at directory: URL) async throws -> Snapshot {
        let path = try await run(["rev-parse", "--show-toplevel"], at: directory).trimmingCharacters(in: .newlines)
        let root = URL(fileURLWithPath: path)
        async let status = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
        async let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], at: root)
        let changes = parseStatus(Data(try await status.utf8))
        let name = (try? await branch.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "No commits yet"
        async let branchList = run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], at: root)
        async let stashList = run(["stash", "list", "-z", "--format=%H%x00%gs"], at: root)
        let branches = try await branchList.split(separator: "\n").map(String.init)
        let fields = try await stashList.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var stashes: [Stash] = []
        for index in stride(from: 0, to: max(0, fields.count - 1), by: 2) {
            let hash = fields[index].trimmingCharacters(in: .newlines)
            if validObjectID(hash) { stashes.append(Stash(id: hash, title: fields[index + 1])) }
        }
        return Snapshot(root: root, branch: name, changes: changes, branches: branches, stashes: stashes)
    }

    private static func paths(_ change: GitChange, includeOriginal: Bool) throws -> [String] {
        let values = [change.path] + (includeOriginal ? change.originalPath.map { [$0] } ?? [] : [])
        guard values.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") }) else {
            throw Failure.command("Invalid repository-relative path.")
        }
        return values
    }

    static func stage(_ change: GitChange, at root: URL) async throws {
        let values = try paths(change, includeOriginal: change.worktree == "R" || change.worktree == "C")
        _ = try await run(["add", "-A", "--"] + values, at: root)
    }
    static func unstage(_ change: GitChange, at root: URL) async throws {
        let values = try paths(change, includeOriginal: change.index == "R" || change.index == "C")
        if (try? await run(["rev-parse", "--verify", "HEAD"], at: root)) != nil {
            _ = try await run(["restore", "--staged", "--source=HEAD", "--"] + values, at: root)
        } else {
            // Before the first commit there is no HEAD to restore from. --cached
            // removes only index entries; the working files remain untouched.
            _ = try await run(["rm", "--cached", "-f", "--"] + values, at: root)
        }
    }
    static func commit(_ message: String, at root: URL) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0"), message.utf8.count <= 64 * 1024 else {
            throw Failure.command("Enter a commit message smaller than 64 KB.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("message")
        try Data(message.utf8).write(to: file)
        _ = try await run(["commit", "--file", file.path], at: root)
    }
    static func switchBranch(_ name: String, create: Bool = false, at root: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.contains("@{") else { throw Failure.command("Enter a valid local branch name.") }
        _ = try await run(["check-ref-format", "--branch", name], at: root)
        // Never force, discard changes, or implicitly create a tracking branch.
        _ = try await run(["switch", "--no-guess"] + (create ? ["-c", name] : [name]), at: root)
    }
    private static func validObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
    static func stashDiff(_ stash: Stash, at root: URL) async throws -> String {
        guard validObjectID(stash.id) else { throw Failure.command("Invalid stash identity.") }
        return try await run(["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", "--no-color", stash.id], at: root)
    }

    static func diff(_ change: GitChange, at root: URL, staged: Bool) async throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if change.untracked {
            args += ["--no-index", "--", "/dev/null", root.appendingPathComponent(change.path).path]
        } else {
            if staged { args.append("--cached") }
            args.append("--")
            args.append(change.path)
            if let original = change.originalPath { args.append(original) }
        }
        return try await run(args, at: root, acceptsDifference: change.untracked)
    }
}
