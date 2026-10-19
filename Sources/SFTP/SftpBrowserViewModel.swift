import Foundation
import SSHClient

@MainActor
final class SftpBrowserViewModel: ObservableObject {
    @Published private(set) var currentPath = "."
    @Published private(set) var items: [SftpItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var operationLabel: String?
    @Published var lastError: String?

    var isWorking: Bool { operationLabel != nil }

    private var connectionID: ObjectIdentifier?
    private var listingID = UUID()
    private var lifetimeID = UUID()

    func reset() {
        connectionID = nil
        listingID = UUID()
        lifetimeID = UUID()
        currentPath = "."
        items = []
        isLoading = false
        operationLabel = nil
        lastError = nil
    }

    func load(using connection: SSHConnection, path: String) async {
        if connectionID != ObjectIdentifier(connection) {
            reset()
            connectionID = ObjectIdentifier(connection)
        }
        let request = UUID()
        listingID = request
        isLoading = true
        lastError = nil
        do {
            let entries = try await SftpManager.shared.listDirectory(connection: connection, path: path)
            guard listingID == request else { return }
            if !Task.isCancelled {
                currentPath = path
                items = entries.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        } catch {
            guard listingID == request else { return }
            if !Task.isCancelled { lastError = error.localizedDescription }
        }
        if listingID == request { isLoading = false }
    }

    func refresh(using connection: SSHConnection) async {
        await load(using: connection, path: connectionID == ObjectIdentifier(connection) ? currentPath : ".")
    }

    func navigateInto(_ item: SftpItem, using connection: SSHConnection) async {
        guard item.isDirectory, !isWorking else { return }
        await load(using: connection, path: item.path)
    }

    func goUp(using connection: SSHConnection) async {
        guard !isWorking, currentPath != "/" else { return }
        await load(using: connection, path: RemotePath.parent(of: currentPath))
    }

    func delete(_ item: SftpItem, using connection: SSHConnection) async {
        await perform("Deleting \(item.name)…", using: connection, refresh: true) {
            try await SftpManager.shared.delete(item: item, connection: connection)
        }
    }

    func rename(_ item: SftpItem, to newName: String, using connection: SSHConnection) async {
        guard validate(name: newName) else { return }
        guard newName != item.name else { return }
        await perform("Renaming…", using: connection, refresh: true) {
            try await SftpManager.shared.rename(item: item, to: newName, connection: connection)
        }
    }

    func createDirectory(named name: String, using connection: SSHConnection) async {
        guard validate(name: name) else { return }
        let path = RemotePath.appending(name, to: currentPath)
        await perform("Creating folder…", using: connection, refresh: true) {
            try await SftpManager.shared.createDirectory(connection: connection, path: path)
        }
    }

    func upload(localURLs: [URL], using connection: SSHConnection) async {
        guard !localURLs.isEmpty else { return }
        let destination = currentPath
        await perform(localURLs.count == 1 ? "Uploading \(localURLs[0].lastPathComponent)…" : "Uploading \(localURLs.count) items…", using: connection, refresh: true) {
            for url in localURLs {
                try Task.checkCancellation()
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
                if isDirectory {
                    try await SftpManager.shared.uploadDirectory(connection: connection, localDirectoryURL: url, into: destination)
                } else {
                    try await SftpManager.shared.uploadFile(connection: connection, localURL: url, into: destination)
                }
            }
        }
    }

    func download(_ item: SftpItem, to localURL: URL, using connection: SSHConnection) async {
        await perform("Downloading \(item.name)…", using: connection) {
            try await SftpManager.shared.downloadFile(connection: connection, item: item, to: localURL)
        }
    }

    func downloadFolder(_ item: SftpItem, into localDirectoryURL: URL, using connection: SSHConnection) async {
        await perform("Downloading \(item.name)…", using: connection) {
            try await SftpManager.shared.downloadDirectory(connection: connection, item: item, into: localDirectoryURL)
        }
    }

    private func validate(name: String) -> Bool {
        guard RemotePath.isValidName(name) else {
            lastError = "Use a name without slashes. The names . and .. are reserved."
            return false
        }
        return true
    }

    private func perform(_ label: String, using connection: SSHConnection, refresh: Bool = false, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        let lifetime = lifetimeID
        operationLabel = label
        lastError = nil
        do {
            try await operation()
            guard lifetimeID == lifetime else { return }
            if refresh { await self.refresh(using: connection) }
        } catch {
            guard lifetimeID == lifetime else { return }
            if !Task.isCancelled { lastError = error.localizedDescription }
        }
        if lifetimeID == lifetime { operationLabel = nil }
    }
}
