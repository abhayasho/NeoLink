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
    struct Snapshot { let root: URL; let branch: String; let changes: [GitChange] }
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
                                                 maximumBytes: 1024 * 1024)
        guard !result.truncated else { throw Failure.tooLarge }
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0 || (acceptsDifference && result.status == 1) else {
            throw Failure.command(output.trimmingCharacters(in: .whitespacesAndNewlines))
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
        return Snapshot(root: root, branch: name, changes: changes)
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
