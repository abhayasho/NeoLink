import SwiftUI
import SSHClient

struct SftpBrowserView: View {
    @ObservedObject var viewModel: SftpBrowserViewModel
    let connection: SSHConnection

    @State private var renameItem: SftpItem?
    @State private var renameText: String = ""
    @State private var newFolderName: String = ""
    @State private var showingDownloadPanelFor: SftpItem?
    @State private var hoveredID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    Task { await viewModel.goUp(using: connection) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                Text(viewModel.currentPath)
                    .font(.system(size: 10))
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    newFolderName = ""
                    renameItem = nil
                    showingDownloadPanelFor = nil
                    showCreateFolderSheet()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if viewModel.items.isEmpty {
                Text("No remote files.")
                    .font(.footnote)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(viewModel.items) { item in
                    row(for: item)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .listRowSeparatorTint(NeoLinkTheme.divider)
                .dropDestination(for: URL.self) { urls, _ in
                    for url in urls {
                        Task { await viewModel.upload(localURL: url, using: connection) }
                    }
                    return true
                }
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.top, 2)
            }
        }
        .onAppear {
            Task { await viewModel.refresh(using: connection) }
        }
        .sheet(item: $renameItem, content: { item in
            renameSheet(item: item)
        })
    }

    private func row(for item: SftpItem) -> some View {
        Button {
            if item.isDirectory {
                Task { await viewModel.navigateInto(item, using: connection) }
            }
        } label: {
            HStack {
                Image(systemName: item.isDirectory ? "folder" : "doc.text")
                    .foregroundColor(item.isDirectory ? NeoLinkTheme.textPrimary : NeoLinkTheme.textSecondary)
                Text(item.name)
                    .foregroundColor(NeoLinkTheme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((hoveredID == item.id) ? NeoLinkTheme.rowHoverWhite : NeoLinkTheme.rowFill)
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
        .onHover { hovering in
            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .contextMenu {
            if item.isDirectory {
                Button("Open") {
                    Task { await viewModel.navigateInto(item, using: connection) }
                }
                Button("Download folder…") {
                    downloadFolder(item: item)
                }
            } else {
                Button("Download…") {
                    download(item: item)
                }
            }
            Button("Rename…") {
                renameText = item.name
                renameItem = item
            }
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(item, using: connection) }
            }
        }
    }

    private func renameSheet(item: SftpItem) -> some View {
        VStack(spacing: 12) {
            Text("Rename remote item")
                .font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { renameItem = nil }
                Button("Save") {
                    let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await viewModel.rename(item, to: newName, using: connection) }
                    renameItem = nil
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    private func showCreateFolderSheet() {
        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "Enter a name for the new remote folder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(string: "")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                Task { await viewModel.createDirectory(named: name, using: connection) }
            }
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

