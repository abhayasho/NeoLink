import SwiftUI
import SSHClient

struct SftpBrowserView: View {
    @EnvironmentObject private var tabsController: TabsController
    @ObservedObject var viewModel: SftpBrowserViewModel
    let connection: SSHConnection
    let endpoint: String

    @State private var nameEditor: NameEditor?
    @State private var nameText = ""
    @State private var filter = ""
    @State private var deleteItem: SftpItem?
    @State private var confirmingDelete = false
    @State private var isDropTargeted = false

    private struct NameEditor: Identifiable {
        let id = UUID()
        let item: SftpItem?
        var isDirectory = true
    }

    private var visibleItems: [SftpItem] {
        filter.isEmpty ? viewModel.items : viewModel.items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var isBusy: Bool { viewModel.isLoading || viewModel.isWorking }

    var body: some View {
        let _ = LayoutTrace.body("SftpBrowserView")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                toolbarButton("Go to parent directory", icon: "arrow.up") {
                    Task { await viewModel.goUp(using: connection) }
                }
                .disabled(isBusy || viewModel.currentPath == "/")
                Text(viewModel.currentPath == "." ? "Home directory" : viewModel.currentPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NeoLinkTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.currentPath)
                Spacer(minLength: 0)
                toolbarButton("Refresh remote files", icon: "arrow.clockwise") {
                    Task { await viewModel.refresh(using: connection) }
                }
                .disabled(isBusy)
                toolbarButton("Upload files or folders", icon: "arrow.up.doc") { upload() }
                    .disabled(isBusy)
                Menu {
                    Button("New File…") { nameText = ""; nameEditor = NameEditor(item: nil, isDirectory: false) }
                    Button("New Folder…") { nameText = ""; nameEditor = NameEditor(item: nil) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Create remote file or folder")
                .disabled(isBusy)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(NeoLinkTheme.textSecondary)
                TextField("Filter remote files", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(NeoLinkTheme.textSecondary)
                        .accessibilityLabel("Clear file filter")
                }
            }
            .padding(8)
            .background(NeoLinkTheme.rowFill, in: RoundedRectangle(cornerRadius: 7))

            ZStack {
                if viewModel.items.isEmpty, viewModel.isLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading remote files…")
                            .font(.system(size: 11))
                            .foregroundColor(NeoLinkTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(visibleItems) { item in
                                SftpRowItemView(
                                    item: item,
                                    isBusy: isBusy,
                                    onOpen: {
                                        if item.isDirectory { Task { await viewModel.navigateInto(item, using: connection) } }
                                        else { open(item) }
                                    },
                                    contextActions: AnyView(sftpContextActions(item))
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NeoLinkTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .allowsHitTesting(false)
                }
            }

            if let error = viewModel.lastError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(NeoLinkTheme.warning)
                    Text(error)
                        .foregroundColor(NeoLinkTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { viewModel.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundColor(NeoLinkTheme.textSecondary)
                        .accessibilityLabel("Dismiss file error")
                }
                .font(.system(size: 10))
                .padding(8)
                .background(NeoLinkTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.mini) }
                Text(viewModel.operationLabel ?? (viewModel.isLoading ? "Refreshing…" : "\(visibleItems.count) \(visibleItems.count == 1 ? "item" : "items")"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !isBusy { Text("Drop to upload").font(.system(size: 9)) }
            }
            .font(.system(size: 10))
            .foregroundColor(NeoLinkTheme.textSecondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isBusy, !urls.isEmpty else { return false }
            Task { await viewModel.upload(localURLs: urls, using: connection) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: ObjectIdentifier(connection)) { await viewModel.refresh(using: connection) }
        .onChange(of: viewModel.currentPath) { _ in filter = "" }
        .sheet(item: $nameEditor) { editor in nameSheet(editor) }
        .alert("Delete remote item?", isPresented: $confirmingDelete, presenting: deleteItem) { item in
            Button("Cancel", role: .cancel) { deleteItem = nil }
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(item, using: connection) }
                deleteItem = nil
            }
        } message: { item in
            Text("“\(item.name)” will be permanently deleted from the server.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: !filter.isEmpty ? "magnifyingglass" : (viewModel.lastError == nil ? "folder" : "wifi.exclamationmark"))
                .font(.system(size: 26, weight: .light))
                .foregroundColor(NeoLinkTheme.textSecondary)
            Text(!filter.isEmpty ? "No matching files" : (viewModel.lastError == nil ? "This folder is empty" : "Couldn’t load files"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NeoLinkTheme.textPrimary)
            Text(!filter.isEmpty ? "Try another file name." : "\(viewModel.lastError == nil ? "Drop files here or use Upload to get started." : "Refresh to try the connection again.")")
                .font(.system(size: 10))
                .foregroundColor(NeoLinkTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if viewModel.lastError != nil {
                Button("Try again") { Task { await viewModel.refresh(using: connection) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundColor(NeoLinkTheme.textSecondary)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func sftpContextActions(_ item: SftpItem) -> some View {
        if item.isDirectory {
            Button("Open") { Task { await viewModel.navigateInto(item, using: connection) } }
            Button("Download folder…") { downloadFolder(item: item) }
        } else {
            Button("Open in Tab") { open(item) }
            Button("Download…") { download(item: item) }
        }
        Divider()
        Button("Rename…") {
            nameText = item.name
            nameEditor = NameEditor(item: item)
        }
        Button("Delete…", role: .destructive) {
            deleteItem = item
            confirmingDelete = true
        }
    }

    private struct SftpRowItemView: View {
        let item: SftpItem
        let isBusy: Bool
        let onOpen: () -> Void
        let contextActions: AnyView
        @State private var isHovered = false

        var body: some View {
            Button {
                onOpen()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .font(.system(size: 13))
                        .foregroundColor(item.isDirectory ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                        .frame(width: 17)
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundColor(NeoLinkTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(NeoLinkTheme.textSecondary.opacity(0.7))
                    } else if let size = item.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(NeoLinkTheme.textSecondary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(isHovered ? NeoLinkTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(item.path)
            .onHover { isHovered = $0 }
            .contextMenu { contextActions }
        }
    }

    private func nameSheet(_ editor: NameEditor) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(editor.item == nil ? (editor.isDirectory ? "New remote folder" : "New remote file") : "Rename remote item", systemImage: editor.item == nil ? "plus" : "pencil")
                .font(.headline)
            TextField("Name", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveName(editor) }
            HStack {
                Spacer()
                Button("Cancel") { nameEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor.item == nil ? "Create" : "Rename") { saveName(editor) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(NeoLinkTheme.editorBackground)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!RemotePath.isValidName(nameText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(22)
        .frame(width: 320)
    }

    private func open(_ item: SftpItem) {
        tabsController.openDocument(WorkspaceDocument(item: item, connection: connection, endpoint: endpoint, browserTabID: tabsController.browserTab?.id))
    }

    private func saveName(_ editor: NameEditor) {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidName(name) else { return }
        Task {
            if let item = editor.item {
                await viewModel.rename(item, to: name, using: connection)
            } else if editor.isDirectory {
                await viewModel.createDirectory(named: name, using: connection)
            } else {
                await viewModel.createFile(named: name, using: connection)
            }
        }
        nameEditor = nil
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.begin { response in
            guard response == .OK else { return }
            Task { await viewModel.upload(localURLs: panel.urls, using: connection) }
        }
    }

    private func download(item: SftpItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.download(item, to: url, using: connection) }
        }
    }

    private func downloadFolder(item: SftpItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.begin { response in
            guard response == .OK, let base = panel.url else { return }
            Task { await viewModel.downloadFolder(item, into: base, using: connection) }
        }
    }
}
