import SwiftUI

struct LocalFileItem: Identifiable, Hashable, Sendable {
    var id: URL { url.standardizedFileURL }
    let url: URL
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64?
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
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey
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
                url: url,
                isDirectory: values?.isDirectory ?? false,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate,
                fileSize: values?.fileSize.map(Int64.init)
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

    func paste() {
        guard let copiedURL else { return }
        copyToCurrentDirectory(from: [copiedURL])
    }

    func rename(item: LocalFileItem, newName: String) {
        performFileOperation(in: item.url.deletingLastPathComponent()) { operations in
            try await operations.rename(item.url, to: newName)
        }
    }

    func open(item: LocalFileItem) {
        if item.isDirectory { navigate(to: item) } else { NSWorkspace.shared.open(item.url) }
    }

    func copyToCurrentDirectory(from sourceURL: URL) {
        copyToCurrentDirectory(from: [sourceURL])
    }

    func copyToCurrentDirectory(from sourceURLs: [URL]) {
        let destination = currentURL
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
            if currentURL.standardizedFileURL == directory.standardizedFileURL {
                load()
            }
            // A failed batch may still have copied earlier files. Refresh, then preserve the error.
            if let operationError { lastError = operationError }
        }
    }
}

struct LocalFileBrowserView: View {
    @ObservedObject var viewModel: LocalFileBrowserViewModel
    @ObservedObject var terminalState: TerminalState
    @State private var renameItem: LocalFileItem?
    @State private var renameText = ""
    @State private var hoveredID: URL?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            navigationBar
            searchBar

            if let error = viewModel.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { viewModel.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss error")
                }
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            fileList
            footer
        }
        .sheet(item: $renameItem) { item in renameSheet(item: item) }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button { viewModel.goUp() } label: {
                Image(systemName: "arrow.up").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentURL.path == "/")
            .help("Open parent folder")
            Menu {
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
                    Image(systemName: "folder.fill").foregroundColor(NeoLinkTheme.accent)
                    Text(viewModel.currentURL.path == "/" ? "Macintosh HD" : viewModel.currentURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .help(viewModel.currentURL.path)
            Spacer(minLength: 0)
            Button { viewModel.load() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .help("Refresh files")
            Menu {
                Toggle("Follow Terminal", isOn: Binding(
                    get: { viewModel.followsTerminal },
                    set: { viewModel.setFollowTerminal($0) }
                ))
                Toggle("Show Hidden Files", isOn: $viewModel.showHiddenFiles)
                Divider()
                Picker("Sort by", selection: $viewModel.sortOrder) {
                    ForEach(FileSortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 22, height: 24) }
            .menuStyle(.borderlessButton)
            .help("File browser options")
        }
        .foregroundColor(NeoLinkTheme.textSecondary)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundColor(NeoLinkTheme.textSecondary)
            TextField("Filter files…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(NeoLinkTheme.editorBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(NeoLinkTheme.panelBorder, lineWidth: 1))
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(viewModel.items) { item in row(for: item) }
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
            if viewModel.isWorking || viewModel.isLoading {
                ProgressView().controlSize(.mini)
            } else if viewModel.copiedURL != nil {
                Button("Paste") { viewModel.paste() }
                    .buttonStyle(.plain)
                    .foregroundColor(NeoLinkTheme.accent)
                    .help("Paste a copy; existing files are kept")
            } else {
                Text(viewModel.searchText.isEmpty ? "\(viewModel.totalItemCount) items" : "\(viewModel.items.count) of \(viewModel.totalItemCount)")
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

    private func row(for item: LocalFileItem) -> some View {
        Button { viewModel.open(item: item) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item))
                    .foregroundColor(item.isDirectory ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(NeoLinkTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 3)
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(NeoLinkTheme.textSecondary.opacity(0.7))
                } else if let size = item.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NeoLinkTheme.textSecondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(hoveredID == item.id ? NeoLinkTheme.rowHoverWhite : .clear))
        }
        .buttonStyle(.plain)
        .help(item.url.path)
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .contextMenu {
            Button("Open") { viewModel.open(item: item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Copy") { viewModel.copy(item: item) }
            if viewModel.copiedURL != nil { Button("Paste") { viewModel.paste() }.disabled(viewModel.isWorking) }
            Button("Rename…") {
                renameText = item.url.lastPathComponent
                renameItem = item
            }
            .disabled(viewModel.isWorking)
            Divider()
            Button("Move to Trash", role: .destructive) { viewModel.delete(item: item) }
                .disabled(viewModel.isWorking)
        }
        .draggable(item.url)
    }

    private func fileIcon(for item: LocalFileItem) -> String {
        switch item.url.pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "html", "css", "json", "sh", "rs", "go": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "svg", "heic": return "photo"
        case "zip", "gz", "tar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc.text"
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
