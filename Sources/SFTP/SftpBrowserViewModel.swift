import Foundation
import SSHClient

@MainActor
final class SftpBrowserViewModel: ObservableObject {
    @Published var currentPath: String = "."
    @Published var items: [SftpItem] = []
    @Published var isLoading = false
    @Published var lastError: String?

    func load(using connection: SSHConnection, path: String) async {
        isLoading = true
        lastError = nil
        do {
            let entries = try await SftpManager.shared.listDirectory(connection: connection, path: path)
            currentPath = path
            items = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func refresh(using connection: SSHConnection) async {
        await load(using: connection, path: currentPath)
    }

    func navigateInto(_ item: SftpItem, using connection: SSHConnection) async {
        guard item.isDirectory else { return }
        await load(using: connection, path: item.path)
    }

    func goUp(using connection: SSHConnection) async {
        let parent: String
        if currentPath == "." || currentPath == "/" {
            parent = currentPath
        } else if let range = currentPath.range(of: "/", options: .backwards) {
            let p = String(currentPath[..<range.lowerBound])
            parent = p.isEmpty ? "." : p
        } else {
            parent = "."
        }
        await load(using: connection, path: parent)
    }

    func delete(_ item: SftpItem, using connection: SSHConnection) async {
        lastError = nil
        do {
            try await SftpManager.shared.delete(item: item, connection: connection)
            await refresh(using: connection)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(_ item: SftpItem, to newName: String, using connection: SSHConnection) async {
        guard !newName.isEmpty else { return }
        lastError = nil
        do {
            try await SftpManager.shared.rename(item: item, to: newName, connection: connection)
            await refresh(using: connection)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createDirectory(named name: String, using connection: SSHConnection) async {
        guard !name.isEmpty else { return }
        lastError = nil
        let newPath: String
        if currentPath == "." {
            newPath = name
        } else if currentPath.hasSuffix("/") {
            newPath = currentPath + name
        } else {
            newPath = currentPath + "/" + name
        }
        do {
            try await SftpManager.shared.createDirectory(connection: connection, path: newPath)
            await refresh(using: connection)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func upload(localURL: URL, using connection: SSHConnection) async {
        lastError = nil
        do {
            let isDir = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try await SftpManager.shared.uploadDirectory(connection: connection, localDirectoryURL: localURL, into: currentPath)
            } else {
                try await SftpManager.shared.uploadFile(connection: connection, localURL: localURL, into: currentPath)
            }
            await refresh(using: connection)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func download(_ item: SftpItem, to localURL: URL, using connection: SSHConnection) async {
        lastError = nil
        do {
            try await SftpManager.shared.downloadFile(connection: connection, item: item, to: localURL)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func downloadFolder(_ item: SftpItem, into localDirectoryURL: URL, using connection: SSHConnection) async {
        lastError = nil
        do {
            try await SftpManager.shared.downloadDirectory(connection: connection, item: item, into: localDirectoryURL)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

