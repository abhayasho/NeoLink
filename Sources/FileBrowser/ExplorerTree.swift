import Foundation
import Darwin

struct ExplorerRow: Identifiable, Sendable {
    /// Identity belongs to the first folder in a compact chain, independent of its label.
    let id: URL
    let item: LocalFileItem
    let name: String
    let depth: Int
    let expanded: Bool
    let missing: Bool
    let git: ExplorerGitSnapshot.State?
    let diagnostics: ExplorerDiagnostics
}

actor ExplorerDirectoryLoader {
    static let shared = ExplorerDirectoryLoader()
    static let maximumEntries = 10_000
    struct Result: Sendable { var children: [URL: [LocalFileItem]]; var limited: Bool }
    func read(_ directory: URL, hidden: Bool, compact: Bool) throws -> Result {
        var current = directory, result = Result(children: [:], limited: false)
        // Inspect only an expanded chain, never recurse into a whole subtree.
        for _ in 0..<16 {
            try Task.checkCancellation()
            let entries = try LocalFileOperations.contents(at: current, showHiddenFiles: hidden)
            result.limited = result.limited || entries.count > Self.maximumEntries
            result.children[current] = FileSortOrder.nameAsc.sorted(Array(entries.prefix(Self.maximumEntries)))
            guard compact, entries.count == 1, let child = entries.first, child.isDirectory,
                  !child.isSymbolicLink, !ProjectSearch.excluded.contains(child.url.lastPathComponent) else { break }
            current = child.url.standardizedFileURL
        }
        return result
    }
}

/// Expanded directories are cached and loaded off the UI thread, two requests at a time.
/// No project-wide watcher/indexer is required for navigation or editor reveal.
@MainActor
final class ExplorerTree: ObservableObject {
    @Published private(set) var rows: [ExplorerRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var limited = false
    @Published private(set) var revealRevision = 0
    @Published private(set) var selectedURL: URL?
    @Published private(set) var git: ExplorerGitSnapshot?
    @Published var error: String?
    private(set) var root: URL?
    private(set) var expanded: Set<URL> = []
    private(set) var children: [URL: [LocalFileItem]] = [:]
    private var loads: [URL: Task<Void, Never>] = [:]
    private var failed: Set<URL> = []
    private var generation = UUID()
    private var gitTask: Task<Void, Never>?
    private var gitGeneration = UUID()
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?
    private var active = false
    private var hidden = false
    private var compact = true
    private var hideIgnored = false
    private var query = ""
    private var diagnostics: [String: ExplorerDiagnostics] = [:]
    private var pendingReveal = false

    deinit {
        loads.values.forEach { $0.cancel() }
        gitTask?.cancel(); refreshTask?.cancel(); watcher?.cancel()
    }
    func configure(root: URL, hidden: Bool, compact: Bool, hideIgnored: Bool) {
        let root = root.standardizedFileURL
        let changedRoot = self.root != root
        let needsReload = changedRoot || self.hidden != hidden || self.compact != compact
        self.hidden = hidden; self.compact = compact; self.hideIgnored = hideIgnored
        if changedRoot { self.root = root; expanded = []; selectedURL = nil; git = nil; pendingReveal = false; observeRoot() }
        if needsReload { reload() } else { rebuild() }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if active { observeRoot(); refreshGit() }
        else { watcher?.cancel(); watcher = nil; refreshTask?.cancel(); gitTask?.cancel() }
    }
    private func observeRoot() {
        watcher?.cancel(); watcher = nil
        guard active, let root else { return }
        let descriptor = Darwin.open(root.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume(); watcher = source
    }
    func scheduleRefresh() {
        guard active else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            self?.reload()
        }
    }
    func reload() {
        generation = UUID()
        loads.values.forEach { $0.cancel() }; loads = [:]
        children = [:]; failed = []; limited = false; error = nil
        pendingReveal = selectedURL != nil
        rebuild(); refreshGit()
    }
    func refreshGit() {
        gitTask?.cancel()
        guard let root else { return }
        let token = UUID(); gitGeneration = token
        gitTask = Task { [weak self] in
            do {
                let snapshot = try await ExplorerGitSnapshot.load(at: root)
                try Task.checkCancellation()
                guard let self, self.gitGeneration == token, self.root == root else { return }
                self.git = snapshot; self.rebuild()
            } catch is CancellationError {} catch {
                guard let self, self.gitGeneration == token else { return }
                self.git = nil; self.rebuild()
            }
        }
    }
    func setFilter(_ query: String) { self.query = query; rebuild() }
    func setDiagnostics(_ diagnostics: [String: ExplorerDiagnostics]) {
        self.diagnostics = Dictionary(diagnostics.map { (URL(fileURLWithPath: $0.key).standardizedFileURL.path, $0.value) }, uniquingKeysWith: +)
        rebuild()
    }
    func collapseAll() { expanded = []; rebuild() }
    func toggle(_ row: ExplorerRow) {
        guard row.item.isDirectory else { return }
        if row.expanded { expanded.remove(row.id) }
        else { expanded.insert(row.id); failed.remove(row.item.url) }
        rebuild()
    }
    /// Reveal only ancestors of the file. Do not enumerate sibling subtrees or change roots.
    func reveal(_ url: URL) {
        guard let root, let path = ExplorerGitSnapshot.relativePath(url, in: root), !path.isEmpty else { return }
        selectedURL = url.standardizedFileURL
        pendingReveal = true
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent != root, ExplorerGitSnapshot.relativePath(parent, in: root) != nil {
            expanded.insert(parent); parent.deleteLastPathComponent()
        }
        rebuild()
    }
    func clearSelection() { selectedURL = nil; pendingReveal = false }
    func rowID(for url: URL?) -> URL? { rows.first(where: { $0.item.url.standardizedFileURL == url?.standardizedFileURL })?.id }

    private func rebuild() {
        guard let root else { return }
        var result: [ExplorerRow] = [], needed: [URL] = []
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func entries(in directory: URL) -> [LocalFileItem] {
            var source = children[directory] ?? []
            let known = Set(source.map(\.id))
            let deleted = (git?.deletedChildren(in: directory) ?? []).filter {
                !known.contains($0.id) && (hidden || !$0.url.lastPathComponent.hasPrefix("."))
            }
            source += deleted
            if !hidden {
                source = source.filter { item in
                    !item.url.lastPathComponent.hasPrefix(".") || selectedURL == item.id ||
                        (item.isDirectory && selectedURL?.path.hasPrefix(item.url.path + "/") == true)
                }
            }
            return deleted.isEmpty ? source : FileSortOrder.nameAsc.sorted(source)
        }
        func walk(_ directory: URL, depth: Int) {
            guard depth < 32, result.count < 5_000 else { limited = true; return }
            if children[directory] == nil, !failed.contains(directory) { needed.append(directory) }
            let known = Set((children[directory] ?? []).map(\.id))
            for original in entries(in: directory) {
                if result.count >= 5_000 { limited = true; break }
                let state = git?.state(for: original.url, directory: original.isDirectory)
                if hideIgnored && state == .ignored { continue }
                var item = original, names = [original.url.lastPathComponent]
                if compact, original.isDirectory, !original.isSymbolicLink {
                    for _ in 0..<16 {
                        let list = entries(in: item.url)
                        guard list.count == 1, let child = list.first, child.isDirectory, !child.isSymbolicLink,
                              children[item.url]?.contains(where: { $0.id == child.id }) == true,
                              !ProjectSearch.excluded.contains(child.url.lastPathComponent),
                              !failed.contains(child.url) else { break }
                        item = child; names.append(child.url.lastPathComponent)
                    }
                }
                let isExpanded = expanded.contains(original.id)
                var counts = diagnostics[item.url.standardizedFileURL.path] ?? ExplorerDiagnostics()
                if item.isDirectory {
                    counts = diagnostics.filter { $0.key.hasPrefix(item.url.path + "/") }.values.reduce(ExplorerDiagnostics(), +)
                }
                let row = ExplorerRow(id: original.id, item: item, name: names.joined(separator: "/"), depth: depth,
                    expanded: isExpanded, missing: !known.contains(original.id), git: state, diagnostics: counts)
                let index = result.count
                result.append(row)
                if isExpanded && item.isDirectory {
                    if row.missing { children[item.url] = children[item.url] ?? [] }
                    walk(item.url, depth: depth + 1)
                }
                // A tree filter deliberately searches loaded branches. Quick Open searches the project.
                if !filter.isEmpty, !row.name.localizedCaseInsensitiveContains(filter), result.count == index + 1 {
                    result.remove(at: index)
                }
            }
        }
        walk(root, depth: 0)
        rows = result
        for directory in needed where loads.count < 2 && loads[directory] == nil {
            if children.count >= 128 { limited = true; continue }
            startLoad(directory)
        }
        isLoading = !loads.isEmpty
        if pendingReveal, rowID(for: selectedURL) != nil { pendingReveal = false; revealRevision += 1 }
    }
    private func startLoad(_ directory: URL) {
        let token = generation, compact = compact && directory != root
        loads[directory] = Task { [weak self] in
            do {
                let loaded = try await ExplorerDirectoryLoader.shared.read(directory, hidden: true, compact: compact)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.loads.removeValue(forKey: directory)
                self.children.merge(loaded.children) { _, new in new }
                self.limited = self.limited || loaded.limited
                self.rebuild()
            } catch is CancellationError {} catch {
                guard let self, self.generation == token else { return }
                self.loads.removeValue(forKey: directory); self.failed.insert(directory)
                self.error = "\(directory.lastPathComponent): \(error.localizedDescription)"; self.rebuild()
            }
        }
    }
}
