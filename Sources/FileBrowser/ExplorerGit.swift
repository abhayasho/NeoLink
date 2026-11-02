import Foundation

/// Only a bounded status query runs; ignored directories are reported without enumeration.
struct ExplorerGitSnapshot: Sendable {
    enum State: String, Sendable { case added = "A", modified = "M", deleted = "D", renamed = "R", untracked = "U", conflict = "!", ignored = "Ignored" }
    let root: URL
    let states: [String: State]
    private let folders: [String: State]
    private let deleted: [String: [String: Bool]]
    init(root: URL, states: [String: State]) {
        self.root = root; self.states = states
        var folders: [String: State] = [:]
        for (path, state) in states where state != .ignored {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let old = folders[parent], old != state {
                    folders[parent] = old == .conflict || state == .conflict ? .conflict : .modified
                } else { folders[parent] = state }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        self.folders = folders
        var deletedNames: [String: [String: Bool]] = [:]
        for (path, state) in states where state == .deleted {
            let parts = path.split(separator: "/").map(String.init)
            for index in parts.indices {
                let parent = parts.prefix(index).joined(separator: "/")
                deletedNames[parent, default: [:]][parts[index]] = index < parts.count - 1
            }
        }
        self.deleted = deletedNames
    }
    static func relativePath(_ url: URL, in root: URL) -> String? {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        if path == base { return "" }
        let prefix = base == "/" ? "/" : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
    func state(for url: URL, directory: Bool) -> State? {
        guard let path = Self.relativePath(url, in: root) else { return nil }
        if let exact = states[path] { return exact }
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if states[parent] == .ignored { return .ignored }
            if states[parent] == .untracked { return .untracked }
            parent = (parent as NSString).deletingLastPathComponent
        }
        guard directory else { return nil }
        return folders[path]
    }
    func deletedChildren(in directory: URL) -> [LocalFileItem] {
        guard let relative = Self.relativePath(directory, in: root) else { return [] }
        return (deleted[relative] ?? [:]).map { name, isDirectory in
            LocalFileItem(url: directory.appendingPathComponent(name), isDirectory: isDirectory,
                          creationDate: nil, modificationDate: nil, fileSize: nil)
        }
    }
    static func load(at directory: URL) async throws -> ExplorerGitSnapshot? {
        let rootResult = try await CommandRunner.run("/usr/bin/git", ["--no-optional-locks", "-C", directory.path, "rev-parse", "--show-toplevel"], timeout: 4, maximumBytes: 16 * 1024)
        guard rootResult.status == 0, !rootResult.truncated else { return nil }
        let root = URL(fileURLWithPath: String(decoding: rootResult.output, as: UTF8.self).trimmingCharacters(in: .newlines)).standardizedFileURL
        let result = try await CommandRunner.run("/usr/bin/git", ["--no-optional-locks", "--literal-pathspecs", "-C", root.path,
            "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal", "--ignore-submodules=all", "--", directory.path], timeout: 5, maximumBytes: 2 * 1024 * 1024)
        guard result.status == 0, !result.truncated else { return nil }
        var states: [String: State] = [:]
        for change in GitChanges.parseStatus(result.output) {
            let path = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let pair = String([change.index, change.worktree])
            let state: State
            if pair == "!!" { state = .ignored }
            else if pair == "??" { state = .untracked }
            else if pair.contains("U") || ["AA", "DD"].contains(pair) { state = .conflict }
            else if pair.contains("D") { state = .deleted }
            else if pair.contains("A") { state = .added }
            else if pair.contains("R") || pair.contains("C") { state = .renamed }
            else { state = .modified }
            states[path] = state
        }
        return ExplorerGitSnapshot(root: root, states: states)
    }
}

struct ExplorerDiagnostics: Equatable, Sendable {
    var errors: Int = 0
    var warnings: Int = 0
    var count: Int { errors + warnings }
    static func + (lhs: Self, rhs: Self) -> Self { Self(errors: lhs.errors + rhs.errors, warnings: lhs.warnings + rhs.warnings) }
}
