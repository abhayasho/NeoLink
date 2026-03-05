import SwiftUI
import SSHClient

struct SftpBrowserView: View {
    @ObservedObject var viewModel: SftpBrowserViewModel
    let connection: SSHConnection

    @State private var renameItem: SftpItem?
    @State private var renameText: String = ""
    @State private var newFolderName: String = ""
    @State private var showingDownloadPanelFor: SftpItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    Task { await viewModel.goUp(using: connection) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Text(viewModel.currentPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

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

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if viewModel.items.isEmpty {
                Text("No remote files.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(viewModel.items) { item in
                    row(for: item)
                }
                .listStyle(.inset)
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
                    .foregroundColor(item.isDirectory ? .accentColor : .primary)
                Text(item.name)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.isDirectory {
                Button("Open") {
                    Task { await viewModel.navigateInto(item, using: connection) }
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
}

