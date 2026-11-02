import SwiftUI

struct LocalFileItem: Identifiable, Hashable, Sendable {
    var id: URL { url.standardizedFileURL }
    let url: URL
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64?
    var isSymbolicLink: Bool = false
}

enum FileSortOrder: String, CaseIterable, Sendable {
    case nameAsc = "Name (A–Z)"
    case nameDesc = "Name (Z–A)"
    case dateModifiedNewest = "Date modified (newest)"
    case dateModifiedOldest = "Date modified (oldest)"
    case dateAddedNewest = "Date added (newest)"
    case dateAddedOldest = "Date added (oldest)"
    case sizeLargest = "Size (largest first)"
    case sizeSmallest = "Size (smallest first)"

    func sorted(_ items: [LocalFileItem]) -> [LocalFileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch self {
            case .nameAsc, .nameDesc:
                comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            case .dateModifiedNewest, .dateModifiedOldest:
                comparison = Self.compare(lhs.modificationDate ?? .distantPast, rhs.modificationDate ?? .distantPast)
            case .dateAddedNewest, .dateAddedOldest:
                comparison = Self.compare(lhs.creationDate ?? .distantPast, rhs.creationDate ?? .distantPast)
            case .sizeLargest, .sizeSmallest:
                comparison = Self.compare(lhs.fileSize ?? 0, rhs.fileSize ?? 0)
            }
            if comparison == .orderedSame {
                let nameOrder = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
                return nameOrder == .orderedSame ? lhs.url.path < rhs.url.path : nameOrder == .orderedAscending
            }
            switch self {
            case .nameDesc, .dateModifiedNewest, .dateAddedNewest, .sizeLargest:
                return comparison == .orderedDescending
            default:
                return comparison == .orderedAscending
            }
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}

enum LocalFileError: LocalizedError {
    case invalidName
    case existingName
    case copyIntoItself

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a name without slashes. A name cannot be just a dot or spaces."
        case .existingName: return "An item with that name already exists. Choose another name."
        case .copyIntoItself: return "A folder cannot be copied into itself or one of its subfolders."
        }
    }
}

/// File mutations are serialized away from the UI. Copying always chooses a new destination;
/// an existing file, including the source itself, is never removed to make room.
actor LocalFileOperations {
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    func create(named name: String, in folder: URL, isDirectory: Bool) throws -> URL {
        guard Self.validName(name) else { throw LocalFileError.invalidName }
        let url = folder.appendingPathComponent(name, isDirectory: isDirectory)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            try Data().write(to: url, options: .withoutOverwriting)
        }
        return url
    }
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey
    ]

    nonisolated static func contents(at directory: URL, showHiddenFiles: Bool) throws -> [LocalFileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )
        return try contents.map { url in
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: resourceKeys)
            return LocalFileItem(
                url: url.standardizedFileURL,
                isDirectory: values?.isDirectory ?? false,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate,
                fileSize: values?.fileSize.map(Int64.init),
                isSymbolicLink: values?.isSymbolicLink ?? false
            )
        }
    }

    @discardableResult
    func copy(_ source: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let sourcePath = resolvedSource.path
            let descendantPrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            if resolvedDirectory == resolvedSource || resolvedDirectory.path.hasPrefix(descendantPrefix) {
                throw LocalFileError.copyIntoItself
            }
        }

        var destination = directory.appendingPathComponent(source.lastPathComponent)
        let name = source.lastPathComponent
        let ext = isDirectory.boolValue ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var copyNumber = 1
        while fileManager.fileExists(atPath: destination.path) {
            let copySuffix = copyNumber == 1 ? " copy" : " copy \(copyNumber)"
            destination = directory.appendingPathComponent(stem + copySuffix + suffix)
            copyNumber += 1
        }
        // copyItem fails if another process creates the destination after the check.
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    func rename(_ source: URL, to name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw LocalFileError.invalidName
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalFileError.existingName }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func moveToTrash(_ source: URL) throws {
        try FileManager.default.trashItem(at: source, resultingItemURL: nil)
    }
}

@MainActor
final class LocalFileBrowserViewModel: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var items: [LocalFileItem] = []
    @Published private(set) var totalItemCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var mutationRevision = 0
    @Published private(set) var followsTerminal = true
    @Published var copiedURL: URL?
    @Published var lastError: String?
    @Published var searchText = "" { didSet { updateDisplayedItems() } }
    @Published var sortOrder: FileSortOrder = .nameAsc { didSet { updateDisplayedItems() } }
    @Published var showHiddenFiles = false { didSet { load() } }

    private let fileOperations = LocalFileOperations()
    private var terminalURL: URL?
    private var rawItems: [LocalFileItem] = []
    private var loadID = UUID()
    private var displayID = UUID()
    private var isEnumerating = false
    private var listingTask: Task<[LocalFileItem], Error>?
    private var displayTask: Task<[LocalFileItem], Never>?

    init(startingAt url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        currentURL = url.standardizedFileURL
        load()
    }

    deinit {
        listingTask?.cancel()
        displayTask?.cancel()
    }

    func load() {
        listingTask?.cancel()
        let requestID = UUID()
        loadID = requestID
        let directory = currentURL
        let hiddenFiles = showHiddenFiles
        lastError = nil
        isEnumerating = true
        isLoading = true
        let task = Task.detached(priority: .userInitiated) {
            try LocalFileOperations.contents(at: directory, showHiddenFiles: hiddenFiles)
        }
        listingTask = task
        Task { [weak self] in
            do {
                let contents = try await task.value
                guard let self, self.loadID == requestID, self.currentURL == directory else { return }
                self.isEnumerating = false
                self.rawItems = contents
                self.totalItemCount = contents.count
                self.updateDisplayedItems()
            } catch {
                guard let self, self.loadID == requestID else { return }
                self.isEnumerating = false
                self.isLoading = false
                self.lastError = error.localizedDescription
            }
        }
    }

    private func updateDisplayedItems() {
        displayTask?.cancel()
        let requestID = UUID()
        displayID = requestID
        let source = rawItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = sortOrder
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [LocalFileItem]() }
            let filtered = query.isEmpty ? source : source.filter {
                $0.url.lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard !Task.isCancelled else { return [LocalFileItem]() }
            return order.sorted(filtered)
        }
        displayTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.displayID == requestID else { return }
            self.items = result
            if !self.isEnumerating { self.isLoading = false }
        }
    }

    func navigate(to item: LocalFileItem) {
        guard item.isDirectory else { return }
        navigate(to: item.url)
    }

    func navigate(to url: URL) {
        followsTerminal = false
        changeDirectory(to: url)
    }

    private func changeDirectory(to url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != currentURL else { return }
        currentURL = standardized
        rawItems = []
        items = []
        totalItemCount = 0
        searchText = ""
        load()
    }

    func goUp() {
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func syncTo(path: String) {
        guard !path.isEmpty, path.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        terminalURL = url
        guard followsTerminal else { return }
        changeDirectory(to: url)
    }

    func setFollowTerminal(_ follow: Bool) {
        followsTerminal = follow
        if follow, let terminalURL { changeDirectory(to: terminalURL) }
    }

    func delete(item: LocalFileItem) {
        performFileOperation(in: item.url.deletingLastPathComponent()) { operations in
            try await operations.moveToTrash(item.url)
        }
    }

    func copy(item: LocalFileItem) {
        copiedURL = item.url
    }

    func paste(into folder: URL? = nil) {
        guard let copiedURL else { return }
        copyFiles(from: [copiedURL], into: folder ?? currentURL)
    }

    func rename(item: LocalFileItem, newName: String) {
        performFileOperation(in: item.url.deletingLastPathComponent()) { operations in
            try await operations.rename(item.url, to: newName)
        }
    }

    func create(named name: String, in folder: URL, isDirectory: Bool) async -> URL? {
        guard !isWorking else { return nil }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let result = try await fileOperations.create(named: name, in: folder, isDirectory: isDirectory)
            mutationRevision &+= 1
            if currentURL == folder { load() }
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func copyToCurrentDirectory(from sourceURL: URL) {
        copyToCurrentDirectory(from: [sourceURL])
    }

    func copyToCurrentDirectory(from sourceURLs: [URL]) {
        copyFiles(from: sourceURLs, into: currentURL)
    }

    func copyFiles(from sourceURLs: [URL], into destination: URL) {
        performFileOperation(in: destination) { operations in
            for source in sourceURLs { try await operations.copy(source, into: destination) }
        }
    }

    private func performFileOperation(
        in directory: URL,
        operation: @escaping @Sendable (LocalFileOperations) async throws -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        Task {
            var operationError: String?
            do { try await operation(fileOperations) }
            catch { operationError = error.localizedDescription }
            isWorking = false
            mutationRevision &+= 1
            if currentURL.standardizedFileURL == directory.standardizedFileURL {
                load()
            }
            // A failed batch may still have copied earlier files. Refresh, then preserve the error.
            if let operationError { lastError = operationError }
        }
    }
}

struct LocalFileBrowserView: View {
    @EnvironmentObject private var tabsController: TabsController
    @ObservedObject var viewModel: LocalFileBrowserViewModel
    @ObservedObject var terminalState: TerminalState
    @State private var renameItem: LocalFileItem?
    @State private var renameText = ""
    @State private var hoveredID: URL?
    @State private var isDropTargeted = false
    @State private var creation: Creation?
    @State private var newName = ""
    @StateObject private var tree = ExplorerTree()
    @AppStorage("explorerTreeMode") private var treeMode = true
    @AppStorage("explorerCompactFolders") private var compactFolders = true
    @AppStorage("explorerAutoReveal") private var autoReveal = true
    @AppStorage("explorerHideIgnored") private var hideIgnored = false

    private struct Creation: Identifiable {
        let id = UUID()
        let directory: URL
        let isDirectory: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            navigationBar
            searchBar

            if let error = viewModel.lastError ?? (treeMode ? tree.error : nil) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { viewModel.lastError = nil; tree.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss error")
                }
                .font(.system(size: 11))
                .foregroundColor(NeoLinkTheme.warning)
                .padding(8)
                .background(NeoLinkTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            if treeMode { treeList } else { fileList }
            footer
        }
        .sheet(item: $renameItem) { item in renameSheet(item: item) }
        .sheet(item: $creation) { item in
            VStack(alignment: .leading, spacing: 16) {
                Label(item.isDirectory ? "New Folder" : "New File", systemImage: item.isDirectory ? "folder.badge.plus" : "doc.badge.plus").font(.headline)
                Text(item.directory.path).font(.caption).foregroundColor(NeoLinkTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                TextField(item.isDirectory ? "Folder name" : "File name, e.g. main.py", text: $newName)
                    .textFieldStyle(.roundedBorder).onSubmit { create(item) }
                HStack {
                    Spacer()
                    Button("Cancel") { creation = nil }.keyboardShortcut(.cancelAction)
                    Button("Create") { create(item) }.keyboardShortcut(.defaultAction)
                        .disabled(!LocalFileOperations.validName(newName))
                }
            }.padding(24).frame(width: 360)
        }
        .task(id: treeConfiguration) { configureTree() }
        .onAppear { tree.setActive(treeMode) }
        .onDisappear { tree.setActive(false) }
        .onChange(of: treeMode) { tree.setActive($0); if $0 { configureTree() } }
        .onChange(of: activeFileURL) { url in
            if autoReveal, let url { tree.reveal(url) }
            else if url == nil { tree.clearSelection() }
        }
        .onChange(of: tabsController.explorerDiagnostics) { tree.setDiagnostics($0) }
        .onChange(of: terminalState.directoryReportRevision) { _ in if treeMode { tree.scheduleRefresh() } }
        .onChange(of: viewModel.mutationRevision) { _ in if treeMode { tree.reload() } }
        .onChange(of: viewModel.isLoading) { loading in if !loading && treeMode { tree.scheduleRefresh() } }
        .onChange(of: viewModel.searchText) { tree.setFilter($0) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkFileSaved)) { _ in if treeMode { tree.scheduleRefresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if treeMode { tree.scheduleRefresh() } }
    }

    private var activeFileURL: URL? {
        guard case .local(let url) = tabsController.selectedTab?.document?.source else { return nil }
        return url
    }
    private var treeConfiguration: String {
        "\(viewModel.currentURL.path)|\(viewModel.showHiddenFiles)|\(compactFolders)|\(hideIgnored)"
    }
    private func configureTree() {
        guard treeMode else { return }
        tree.configure(root: viewModel.currentURL, hidden: viewModel.showHiddenFiles, compact: compactFolders, hideIgnored: hideIgnored)
        tree.setDiagnostics(tabsController.explorerDiagnostics)
        tree.setFilter(viewModel.searchText)
        if autoReveal, let url = activeFileURL { tree.reveal(url) }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New File…") { beginCreate(in: viewModel.currentURL, isDirectory: false) }
                Button("New Folder…") { beginCreate(in: viewModel.currentURL, isDirectory: true) }
            } label: { Image(systemName: "plus").frame(width: 22, height: 24) }
            .menuStyle(.borderlessButton)
            .help("Create file or folder")
            .disabled(viewModel.isWorking)
            Menu {
                Button("Parent Folder", systemImage: "arrow.up") { viewModel.goUp() }
                    .disabled(viewModel.currentURL.path == "/")
                Button("Home", systemImage: "house") {
                    viewModel.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                Divider()
                ForEach(ancestors, id: \.self) { url in
                    Button(url.path) { viewModel.navigate(to: url) }
                }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: viewModel.currentURL.path) }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.currentURL.path == "/" ? "Macintosh HD" : viewModel.currentURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .help(viewModel.currentURL.path)
            .frame(maxWidth: .infinity, alignment: .leading)
            if treeMode {
                Button { tree.collapseAll() } label: { Image(systemName: "rectangle.compress.vertical").frame(width: 22, height: 24) }
                    .buttonStyle(.plain).help("Collapse all folders").accessibilityLabel("Collapse all folders")
            }
            Button { viewModel.load(); if treeMode { tree.reload() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .help("Refresh files")
            Menu {
                Picker("Explorer layout", selection: $treeMode) {
                    Text("Project Tree").tag(true)
                    Text("Folder List").tag(false)
                }
                Toggle("Compact Folders", isOn: $compactFolders).disabled(!treeMode)
                Toggle("Reveal Active File", isOn: $autoReveal).disabled(!treeMode)
                Toggle("Hide Git-Ignored Files", isOn: $hideIgnored).disabled(!treeMode)
                Divider()
                Toggle("Follow Terminal", isOn: Binding(
                    get: { viewModel.followsTerminal },
                    set: { viewModel.setFollowTerminal($0) }
                ))
                Toggle("Show Hidden Files", isOn: $viewModel.showHiddenFiles)
                Divider()
                Picker("Sort by", selection: $viewModel.sortOrder) {
                    ForEach(FileSortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(treeMode)
            } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 22, height: 24) }
            .menuStyle(.borderlessButton)
            .help("File browser options")
        }
        .foregroundColor(NeoLinkTheme.textSecondary)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundColor(NeoLinkTheme.textSecondary)
            TextField(treeMode ? "Filter tree…" : "Filter files…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .help(treeMode ? "Filter loaded branches. Use ⌘P to search the entire project." : "Filter this folder")
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .help("Clear filter")
            }
            Button { NotificationCenter.default.post(name: .neoLinkQuickOpen, object: nil) } label: { Text("⌘P").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(NeoLinkTheme.textSecondary).help("Quick Open: fuzzy search project files")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(NeoLinkTheme.editorBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(NeoLinkTheme.panelBorder, lineWidth: 1))
    }

    private var treeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.rows) { entry in
                        row(for: entry.item, selected: entry.item.id == activeFileURL?.standardizedFileURL, entry: entry)
                            .id(entry.id)
                    }
                }.padding(.vertical, 2)
            }
            .onChange(of: tree.revealRevision) { _ in
                if let id = tree.rowID(for: tree.selectedURL) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay {
                if tree.rows.isEmpty {
                    VStack(spacing: 8) {
                        if tree.isLoading { ProgressView().controlSize(.small) }
                        Text(tree.isLoading ? "Loading folder…" : (tree.error ?? (viewModel.searchText.isEmpty ? "This folder is empty" : "No matches in expanded folders")))
                        if !viewModel.searchText.isEmpty { Button("Search entire project  ⌘P") { NotificationCenter.default.post(name: .neoLinkQuickOpen, object: nil) } }
                    }.font(.system(size: 11)).foregroundStyle(NeoLinkTheme.textSecondary).padding(10)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !viewModel.isWorking, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                viewModel.copyToCurrentDirectory(from: urls); return true
            } isTargeted: { isDropTargeted = $0 }
            .background(isDropTargeted ? NeoLinkTheme.selection : Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        // Resolve only the matching filename, not every entry in a large directory.
        let selectedURL: URL? = {
            guard case .local(let url) = tabsController.selectedTab?.document?.source else { return nil }
            return viewModel.items.first {
                $0.url.lastPathComponent == url.lastPathComponent && $0.url.resolvingSymlinksInPath() == url
            }?.id
        }()
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(viewModel.items) { item in row(for: item, selected: item.id == selectedURL) }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if viewModel.items.isEmpty {
                VStack(spacing: 9) {
                    if viewModel.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Loading files…")
                    } else {
                        Image(systemName: viewModel.lastError == nil ? "folder" : "folder.badge.questionmark")
                            .font(.system(size: 25, weight: .light))
                        Text(emptyMessage)
                        if viewModel.lastError != nil {
                            Button("Try Again") { viewModel.load() }.buttonStyle(.plain)
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(NeoLinkTheme.textSecondary)
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? NeoLinkTheme.accent.opacity(0.08) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isDropTargeted ? NeoLinkTheme.accent : .clear, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard !viewModel.isWorking, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            viewModel.copyToCurrentDirectory(from: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.setFollowTerminal(!viewModel.followsTerminal)
            } label: {
                Label(viewModel.followsTerminal ? "Following terminal" : "Follow terminal", systemImage: viewModel.followsTerminal ? "link" : "link.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.followsTerminal ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            .help(viewModel.followsTerminal ? "Pause folder synchronization" : "Return to the terminal’s current folder")
            Spacer(minLength: 0)
            if viewModel.isWorking || viewModel.isLoading || (treeMode && tree.isLoading) {
                ProgressView().controlSize(.mini)
            } else if viewModel.copiedURL != nil {
                Button("Paste") { viewModel.paste() }
                    .buttonStyle(.plain)
                    .foregroundColor(NeoLinkTheme.accent)
                    .help("Paste a copy; existing files are kept")
            } else {
                Text(treeMode ? (tree.limited ? "Tree limit · use ⌘P" : "\(tree.rows.count) visible") : (viewModel.searchText.isEmpty ? "\(viewModel.totalItemCount) items" : "\(viewModel.items.count) of \(viewModel.totalItemCount)"))
                    .foregroundColor(NeoLinkTheme.textSecondary)
            }
        }
        .font(.system(size: 10))
        .padding(.top, 4)
        .overlay(alignment: .top) { NeoLinkTheme.horizontalSeparator() }
    }

    private var emptyMessage: String {
        if viewModel.lastError != nil { return "Couldn’t load this folder" }
        return viewModel.searchText.isEmpty ? "This folder is empty" : "No files match your filter"
    }

    private var ancestors: [URL] {
        var urls = [viewModel.currentURL]
        while let last = urls.last, last.path != "/" {
            urls.append(last.deletingLastPathComponent())
        }
        return urls
    }

    private func row(for item: LocalFileItem, selected: Bool, entry: ExplorerRow? = nil) -> some View {
        let stateLabel = entry?.git?.label ?? ""
        let title = entry?.name ?? item.url.lastPathComponent
        let diagnosticsLabel = entry.map { $0.diagnostics.count > 0 ? ", \($0.diagnostics.errors) errors, \($0.diagnostics.warnings) warnings" : "" } ?? ""
        return Button {
            if let entry, item.isDirectory { tree.toggle(entry) }
            else if entry?.missing != true { open(item) }
        } label: { rowLabel(item, selected: selected, entry: entry) }
        .buttonStyle(.plain)
        .opacity(entry?.git == .ignored ? 0.55 : 1)
        .help(item.url.path + (stateLabel.isEmpty ? "" : " — " + stateLabel))
        .accessibilityLabel(title + (item.isDirectory ? (entry?.expanded == true ? ", expanded folder" : ", folder") : "") + (stateLabel.isEmpty ? "" : ", " + stateLabel) + diagnosticsLabel)
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .contextMenu { contextActions(item, entry: entry) }
        .draggable(item.url)
        .dropDestination(for: URL.self) { urls, _ in
            guard item.isDirectory, entry?.missing != true, !viewModel.isWorking,
                  !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            viewModel.copyFiles(from: urls, into: item.url); return true
        }
    }

    private func rowLabel(_ item: LocalFileItem, selected: Bool, entry: ExplorerRow?) -> some View {
        HStack(spacing: 5) {
            if let entry {
                Image(systemName: entry.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(NeoLinkTheme.textSecondary).frame(width: 10)
                    .opacity(item.isDirectory ? 1 : 0).accessibilityHidden(true)
            }
            SemanticFileIcon(url: item.url, directory: item.isDirectory, expanded: entry?.expanded ?? false)
            Text(entry?.name ?? item.url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundColor(entry?.git?.color ?? NeoLinkTheme.textPrimary)
                .strikethrough(entry?.missing == true && !item.isDirectory)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 3)
            if let entry, entry.diagnostics.count > 0 {
                Text("\(entry.diagnostics.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(entry.diagnostics.errors > 0 ? NeoLinkTheme.error : NeoLinkTheme.warning)
                    .help("\(entry.diagnostics.errors) errors, \(entry.diagnostics.warnings) warnings in open buffers")
            }
            if let state = entry?.git, state != .ignored {
                Text(state.rawValue).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(state.color).help(state.label)
            } else if item.isDirectory && entry == nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(NeoLinkTheme.textSecondary.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(entry?.depth ?? 0) * 12)
        .contentShape(Rectangle())
        .background(selected ? NeoLinkTheme.selection : (hoveredID == item.id ? NeoLinkTheme.rowHoverWhite : .clear))
    }

    @ViewBuilder
    private func contextActions(_ item: LocalFileItem, entry: ExplorerRow?) -> some View {
            if entry?.missing == true {
                Button("Review Deletion in Source Control") { NotificationCenter.default.post(name: .neoLinkShowGit, object: tree.git?.root) }
            } else {
            Button(item.isDirectory ? "Browse This Folder" : "Open in Tab") { open(item) }
            if item.isDirectory {
                Button("New File Here…") { beginCreate(in: item.url, isDirectory: false) }
                Button("New Folder Here…") { beginCreate(in: item.url, isDirectory: true) }
            }
            if !item.isDirectory {
                Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Open in Integrated Terminal") { tabsController.openTerminal(in: item.isDirectory ? item.url : item.url.deletingLastPathComponent()) }
            Button("Reveal Active File") { revealActiveFile() }.disabled(activeFileURL == nil)
            Divider()
            Button("Copy Path") { copyPath(item.url.path) }
            Button("Copy Relative Path") { copyPath(ExplorerGitSnapshot.relativePath(item.url, in: WorkspaceAccess.shared.projectURL ?? viewModel.currentURL) ?? item.url.path) }
            Divider()
            Button("Copy") { viewModel.copy(item: item) }
            if viewModel.copiedURL != nil { Button("Paste Here") { viewModel.paste(into: item.isDirectory ? item.url : item.url.deletingLastPathComponent()) }.disabled(viewModel.isWorking) }
            Button("Rename…") {
                renameText = item.url.lastPathComponent
                renameItem = item
            }
            .disabled(viewModel.isWorking)
            Divider()
            Button("Move to Trash", role: .destructive) { viewModel.delete(item: item) }
                .disabled(viewModel.isWorking)
            }
    }

    private func copyPath(_ path: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
    private func revealActiveFile() {
        guard let url = activeFileURL else { return }
        if ExplorerGitSnapshot.relativePath(url, in: viewModel.currentURL) == nil { viewModel.navigate(to: url.deletingLastPathComponent()) }
        tree.reveal(url)
    }

    private func open(_ item: LocalFileItem) {
        if item.isDirectory { viewModel.navigate(to: item) }
        else { tabsController.openFile(item.url) }
    }

    private func beginCreate(in directory: URL, isDirectory: Bool) {
        newName = ""
        creation = Creation(directory: directory, isDirectory: isDirectory)
    }

    private func create(_ item: Creation) {
        guard LocalFileOperations.validName(newName) else { return }
        let name = newName
        creation = nil
        Task {
            if let url = await viewModel.create(named: name, in: item.directory, isDirectory: item.isDirectory), !item.isDirectory {
                tabsController.openFile(url)
            }
        }
    }

    private func renameSheet(item: LocalFileItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename item").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitRename(item) }
            HStack {
                Spacer()
                Button("Cancel") { renameItem = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { submitRename(item) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!renameIsValid)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private var renameIsValid: Bool {
        !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !renameText.contains("/") && !renameText.contains("\0") && renameText != "." && renameText != ".."
    }

    private func submitRename(_ item: LocalFileItem) {
        guard renameIsValid else { return }
        viewModel.rename(item: item, newName: renameText)
        renameItem = nil
    }
}
