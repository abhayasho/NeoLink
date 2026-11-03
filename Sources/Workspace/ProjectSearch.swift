import SwiftUI

struct ProjectMatch: Identifiable, Sendable {
    let path: String
    let line: Int?
    let preview: String
    var id: String { "\(path):\(line ?? 0)" }
}

enum ProjectSearch {
    static let excluded = [".git", "node_modules", ".build", "build", "dist", ".venv", "venv", "__pycache__", "DerivedData", ".next", "vendor", "Pods", "target"]
    static var arguments: [String] { ["--no-config", "--threads", "2", "--hidden", "--no-messages"] + excluded.flatMap { ["--glob", "!**/\($0)/**"] } }
    static func files(in root: URL) async throws -> [String] {
        guard let rg = CommandRunner.executable("rg") else { throw SearchError.missingTool }
        let result = try await CommandRunner.run(rg, ["--files", "-0"] + arguments + ["--", "."], directory: root)
        guard result.status == 0 || result.status == 1 || result.truncated else { throw SearchError.failed }
        // If truncated, discard the incomplete trailing path.
        let paths = result.output.split(separator: 0, omittingEmptySubsequences: true)
        return paths.prefix(result.truncated ? max(0, paths.count - 1) : paths.count).prefix(50_000)
            .map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "^\\./", with: "", options: .regularExpression) }.sorted()
    }
    static func filter(_ files: [String], query: String) -> [ProjectMatch] {
        let terms = query.prefix(256).lowercased().split(whereSeparator: \.isWhitespace).prefix(16).map(String.init)
        guard !terms.isEmpty else { return files.prefix(100).map { ProjectMatch(path: $0, line: nil, preview: "") } }
        return files.compactMap { path -> (String, Int)? in
            guard !Task.isCancelled else { return nil }
            let value = path.lowercased()
            var total = 0
            for term in terms {
                guard let score = fuzzyScore(term, in: value) else { return nil }
                total += score
            }
            return (path, total)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(100)
            .map { ProjectMatch(path: $0.0, line: nil, preview: "") }
    }
    static func filteredFiles(_ files: [String], query: String) async throws -> [ProjectMatch] {
        let worker = Task.detached(priority: .userInitiated) { filter(files, query: query) }
        return try await withTaskCancellationHandler {
            let result = await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
    /// Subsequence matching rewards contiguous runs, filename starts, and path boundaries.
    static func fuzzyScore(_ query: String, in path: String) -> Int? {
        let needle = Array(query), haystack = Array(path)
        guard !needle.isEmpty else { return 0 }
        var position = 0, previous = -2, score = 0
        for character in needle {
            guard let next = haystack[position...].firstIndex(of: character) else { return nil }
            score += next == previous + 1 ? 18 : 1
            if next == 0 || "/._- ".contains(haystack[next - 1]) { score += 12 }
            score -= next - position
            previous = next; position = next + 1
        }
        let name = (path as NSString).lastPathComponent
        if name == query { score += 200 }
        else if name.hasPrefix(query) { score += 100 }
        else if name.contains(query) { score += 50 }
        return score - min(100, haystack.count - needle.count)
    }
    static func matches(in root: URL, query: String) async throws -> [ProjectMatch] {
        guard !query.isEmpty else { return [] }
        guard let rg = CommandRunner.executable("rg") else { throw SearchError.missingTool }
        let result = try await CommandRunner.run(rg, ["--json", "--fixed-strings", "--smart-case", "--max-count", "20", "--max-filesize", "2M"] + arguments + ["--", query, "."], directory: root, timeout: 10, maximumBytes: 2 * 1024 * 1024)
        guard result.status == 0 || result.status == 1 || result.truncated else { throw SearchError.failed }
        var matches: [ProjectMatch] = []
        for line in result.output.split(separator: 10) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], json["type"] as? String == "match",
                  let data = json["data"] as? [String: Any], let path = (data["path"] as? [String: Any])?["text"] as? String,
                  let number = data["line_number"] as? Int,
                  let content = (data["lines"] as? [String: Any])?["text"] as? String else { continue }
            matches.append(ProjectMatch(path: path.hasPrefix("./") ? String(path.dropFirst(2)) : path, line: number,
                preview: String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250))))
            if matches.count == 200 { break }
        }
        return matches
    }
    enum SearchError: LocalizedError {
        case missingTool, failed
        var errorDescription: String? {
            switch self {
            case .missingTool: return "Project search needs ripgrep. Install it with brew install ripgrep."
            case .failed: return "Search could not finish. Check folder access or try a smaller project."
            }
        }
    }
}

struct ProjectSearchSheet: View {
    let root: URL
    let searchContents: Bool
    let open: (URL, Int?) -> Void
    /// Dismiss. Defaults to the SwiftUI sheet dismiss; an overlay host passes its own closer.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @State private var query = ""
    @State private var files: [String] = []
    @State private var matches: [ProjectMatch] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(searchContents ? "Find in Files" : "Quick Open", systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Text(root.lastPathComponent).foregroundColor(NeoLinkTheme.textSecondary)
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }
            TextField(searchContents ? "Search project contents…" : "Find a file by name or path…", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let first = matches.first { choose(first) } }
            if let error { Text(error).foregroundColor(NeoLinkTheme.warning).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(matches) { match in
                        Button { choose(match) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.path + (match.line.map { ":\($0)" } ?? "")).font(.system(size: 12, weight: .medium)).foregroundColor(NeoLinkTheme.textPrimary)
                                if !match.preview.isEmpty { Text(match.preview).font(.system(size: 11, design: .monospaced)).foregroundColor(NeoLinkTheme.textSecondary).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(NeoLinkTheme.rowFill, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty && !loading { Text(query.isEmpty && searchContents ? "Enter text to search this project." : "No matching files").foregroundColor(NeoLinkTheme.textSecondary).padding(.vertical) }
                }
            }.frame(height: 340)
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Text(searchContents ? "Up to 200 matches · 20 per file · files under 2 MB" : "\(files.count) indexed files · up to 100 shown")
                Spacer()
            }.font(.system(size: 10)).foregroundColor(NeoLinkTheme.textSecondary)
            Text("Respects .gitignore. Dependency and build folders are skipped.").font(.system(size: 10)).foregroundColor(NeoLinkTheme.textSecondary)
        }
        .padding(20).frame(width: 630).background(NeoLinkTheme.panelBackground).preferredColorScheme(.dark)
        .task {
            focused = true
            if !searchContents {
                loading = true
                defer { loading = false }
                do {
                    files = try await ProjectSearch.files(in: root)
                    let source = files, search = query
                    let result = try await ProjectSearch.filteredFiles(source, query: search)
                    try Task.checkCancellation()
                    if query == search { matches = result }
                }
                catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        }
        .task(id: query) {
            if !searchContents {
                let source = files, search = query
                do { matches = try await ProjectSearch.filteredFiles(source, query: search) }
                catch is CancellationError {} catch { self.error = error.localizedDescription }
                return
            }
            loading = true; error = nil
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let results = try await ProjectSearch.matches(in: root, query: query)
                try Task.checkCancellation()
                matches = results; loading = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
    private func choose(_ match: ProjectMatch) { open(root.appendingPathComponent(match.path), match.line); close() }
}
