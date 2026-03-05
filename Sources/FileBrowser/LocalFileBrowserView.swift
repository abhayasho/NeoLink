import SwiftUI

struct LocalFileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64?
}

enum FileSortOrder: String, CaseIterable {
    case nameAsc = "Name (A–Z)"
    case nameDesc = "Name (Z–A)"
    case dateModifiedNewest = "Date modified (newest)"
    case dateModifiedOldest = "Date modified (oldest)"
    case dateAddedNewest = "Date added (newest)"
    case dateAddedOldest = "Date added (oldest)"
    case sizeLargest = "Size (largest first)"
    case sizeSmallest = "Size (smallest first)"
}

@MainActor
final class LocalFileBrowserViewModel: ObservableObject {
    @Published var currentURL: URL
    @Published var items: [LocalFileItem] = []
    @Published var copiedURL: URL?
    @Published var lastError: String?
    @Published var sortOrder: FileSortOrder = .nameAsc
    private var userNavigated = false

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey
    ]

    init(startingAt url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
        load()
    }

    func load() {
        lastError = nil
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: Array(Self.resourceKeys), options: [.skipsHiddenFiles]) else {
            items = []
            return
        }
        let raw: [LocalFileItem] = contents.map { url in
            let vals = try? url.resourceValues(forKeys: Self.resourceKeys)
            let isDir = vals?.isDirectory ?? false
            return LocalFileItem(
                url: url,
                isDirectory: isDir,
                creationDate: vals?.creationDate,
                modificationDate: vals?.contentModificationDate,
                fileSize: vals?.fileSize.map { Int64($0) } ?? nil
            )
        }
        items = applySort(raw)
    }

    private func applySort(_ raw: [LocalFileItem]) -> [LocalFileItem] {
        func foldersFirst(_ a: LocalFileItem, _ b: LocalFileItem, by areInOrder: (LocalFileItem, LocalFileItem) -> Bool) -> Bool {
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return areInOrder(a, b)
        }
        switch sortOrder {
        case .nameAsc:
            return raw.sorted { foldersFirst($0, $1) { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending } }
        case .nameDesc:
            return raw.sorted { foldersFirst($0, $1) { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending } }
        case .dateModifiedNewest:
            return raw.sorted { foldersFirst($0, $1) { ($0.modificationDate ?? .distantPast) >= ($1.modificationDate ?? .distantPast) } }
        case .dateModifiedOldest:
            return raw.sorted { foldersFirst($0, $1) { ($0.modificationDate ?? .distantPast) <= ($1.modificationDate ?? .distantPast) } }
        case .dateAddedNewest:
            return raw.sorted { foldersFirst($0, $1) { ($0.creationDate ?? .distantPast) >= ($1.creationDate ?? .distantPast) } }
        case .dateAddedOldest:
            return raw.sorted { foldersFirst($0, $1) { ($0.creationDate ?? .distantPast) <= ($1.creationDate ?? .distantPast) } }
        case .sizeLargest:
            return raw.sorted { foldersFirst($0, $1) { ($0.fileSize ?? 0) >= ($1.fileSize ?? 0) } }
        case .sizeSmallest:
            return raw.sorted { foldersFirst($0, $1) { ($0.fileSize ?? 0) <= ($1.fileSize ?? 0) } }
        }
    }

    func navigate(to item: LocalFileItem) {
        guard item.isDirectory else { return }
        userNavigated = true
        currentURL = item.url
        load()
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent.path != currentURL.path {
            userNavigated = true
            currentURL = parent
            load()
        }
    }

    func syncTo(path: String) {
        guard !userNavigated else { return }
        let url = URL(fileURLWithPath: path)
        guard url.path != currentURL.path else { return }
        currentURL = url
        load()
    }

    func delete(item: LocalFileItem) {
        lastError = nil
        do {
            try FileManager.default.removeItem(at: item.url)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copy(item: LocalFileItem) {
        copiedURL = item.url
    }

    func paste() {
        guard let src = copiedURL else { return }
        lastError = nil
        let dst = currentURL.appendingPathComponent(src.lastPathComponent)
        do {
            if (try? dst.checkResourceIsReachable()) == true {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(item: LocalFileItem, newName: String) {
        guard !newName.isEmpty else { return }
        lastError = nil
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func open(item: LocalFileItem) {
        NSWorkspace.shared.open(item.url)
    }

    func copyToCurrentDirectory(from sourceURL: URL) {
        lastError = nil
        let name = sourceURL.lastPathComponent
        let dst = currentURL.appendingPathComponent(name)
        do {
            if (try? dst.checkResourceIsReachable()) == true {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dst)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct LocalFileBrowserView: View {
    @ObservedObject var viewModel: LocalFileBrowserViewModel
    @ObservedObject var terminalState: TerminalState
    @State private var renameItem: LocalFileItem?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    viewModel.goUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Text(viewModel.currentURL.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Menu {
                    ForEach(FileSortOrder.allCases, id: \.self) { order in
                        Button(viewModel.sortOrder == order ? "✓ \(order.rawValue)" : order.rawValue) {
                            viewModel.sortOrder = order
                            viewModel.load()
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 4)

            if let err = viewModel.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
            }

            List {
                if viewModel.copiedURL != nil {
                    Button("Paste") {
                        viewModel.paste()
                    }
                    .buttonStyle(.plain)
                }
                ForEach(viewModel.items) { item in
                    row(for: item)
                }
            }
            .listStyle(.inset)
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls { viewModel.copyToCurrentDirectory(from: url) }
                return true
            }
        }
        .sheet(item: $renameItem) { item in
            renameSheet(item: item)
        }
    }

    private func row(for item: LocalFileItem) -> some View {
        Button {
            if item.isDirectory {
                viewModel.navigate(to: item)
                terminalState.pendingCommand = "cd \(item.url.path)\n"
            }
        } label: {
            HStack {
                Image(systemName: item.isDirectory ? "folder" : "doc.text")
                Text(item.url.lastPathComponent)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            viewModel.open(item: item)
        }
        .contextMenu {
            Button("Open") { viewModel.open(item: item) }
            Button("Copy") { viewModel.copy(item: item) }
            if viewModel.copiedURL != nil {
                Button("Paste") { viewModel.paste() }
            }
            Button("Rename…") {
                renameText = item.url.lastPathComponent
                renameItem = item
            }
            Button("Delete", role: .destructive) { viewModel.delete(item: item) }
        }
        .draggable(item.url)
    }

    private func renameSheet(item: LocalFileItem) -> some View {
        VStack(spacing: 12) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { renameItem = nil }
                Button("Rename") {
                    viewModel.rename(item: item, newName: renameText)
                    renameItem = nil
                }
            }
        }
        .padding()
        .frame(minWidth: 260)
    }
}

