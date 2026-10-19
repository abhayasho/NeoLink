import Foundation
import SSHClient

@MainActor
final class SftpManager {
    static let shared = SftpManager()
    private init() {}

    private struct ClientRequest {
        let id: UUID
        let task: Task<SFTPClient, Error>
    }
    private var clients: [ObjectIdentifier: ClientRequest] = [:]

    /// Reuse the SFTP channel for browsing and transfers instead of opening one for every action.
    private func client(for connection: SSHConnection) async throws -> SFTPClient {
        let key = ObjectIdentifier(connection)
        let request: ClientRequest
        if let existing = clients[key] {
            request = existing
        } else {
            request = ClientRequest(id: UUID(), task: Task { try await connection.requestSFTPClient() })
            clients[key] = request
        }
        do {
            let client = try await request.task.value
            guard clients[key]?.id == request.id else { throw CancellationError() }
            let requestID = request.id
            client.closeHandler = { [weak self] _ in
                Task { @MainActor in
                    if self?.clients[key]?.id == requestID { self?.clients.removeValue(forKey: key) }
                }
            }
            return client
        } catch {
            if clients[key]?.id == request.id { clients.removeValue(forKey: key) }
            throw error
        }
    }

    func release(connection: SSHConnection) {
        guard let request = clients.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        Task {
            if let client = try? await request.task.value { await client.close() }
        }
    }

    func listDirectory(connection: SSHConnection, path: String) async throws -> [SftpItem] {
        let client = try await client(for: connection)
        let entries = try await client.listDirectory(at: SFTPFilePath(path))
        return entries.compactMap { entry in
            let name = entry.filename.string
            guard name != ".", name != "..", RemotePath.isValidName(name) else { return nil }
            return SftpItem(
                path: RemotePath.appending(name, to: path),
                name: name,
                isDirectory: entry.attributes.permissions.map { $0 & 0o170000 == 0o040000 } ?? (entry.longname.first == "d"),
                size: entry.attributes.size,
                modifiedAt: entry.attributes.accessModificationTime?.modificationTime
            )
        }
    }

    func createDirectory(connection: SSHConnection, path: String) async throws {
        let client = try await client(for: connection)
        try await client.createDirectory(at: SFTPFilePath(path))
    }

    func delete(item: SftpItem, connection: SSHConnection) async throws {
        let client = try await client(for: connection)
        if item.isDirectory {
            try await client.removeDirectory(at: SFTPFilePath(item.path))
        } else {
            try await client.removeFile(at: SFTPFilePath(item.path))
        }
    }

    func rename(item: SftpItem, to newName: String, connection: SSHConnection) async throws {
        let client = try await client(for: connection)
        let destination = RemotePath.appending(newName, to: RemotePath.parent(of: item.path))
        try await client.moveItem(at: SFTPFilePath(item.path), to: SFTPFilePath(destination))
    }

    func uploadFile(connection: SSHConnection, localURL: URL, into remoteDirectory: String) async throws {
        let client = try await client(for: connection)
        let path = SFTPFilePath(RemotePath.appending(localURL.lastPathComponent, to: remoteDirectory))
        try await transfer {
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            let file = try await client.openFile(at: path, flags: [.create, .write, .truncate])
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: 256 * 1024), !data.isEmpty else { break }
                    try await file.write(data, at: offset)
                    offset += UInt64(data.count)
                }
            } catch {
                try? await file.close()
                throw error
            }
            try await file.close()
        }
    }

    func uploadDirectory(connection: SSHConnection, localDirectoryURL: URL, into remoteDirectory: String) async throws {
        let targetRoot = RemotePath.appending(localDirectoryURL.lastPathComponent, to: remoteDirectory)
        try await ensureDirectory(connection: connection, path: targetRoot)
        try await uploadContents(connection: connection, localDirectory: localDirectoryURL, remoteDirectory: targetRoot)
    }

    private func ensureDirectory(connection: SSHConnection, path: String) async throws {
        let client = try await client(for: connection)
        do {
            try await client.createDirectory(at: SFTPFilePath(path))
        } catch {
            // An existing directory is fine; a permission error or existing file is not.
            let attributes = try? await client.getAttributes(at: SFTPFilePath(path))
            guard let mode = attributes?.permissions, mode & 0o170000 == 0o040000 else { throw error }
        }
    }

    private func uploadContents(connection: SSHConnection, localDirectory: URL, remoteDirectory: String) async throws {
        let children = try await Task.detached(priority: .utility) {
            try FileManager.default.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        }.value
        for url in children {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Avoid following directory symlinks outside the selected folder.
            if values.isDirectory == true, values.isSymbolicLink != true {
                let path = RemotePath.appending(url.lastPathComponent, to: remoteDirectory)
                try await ensureDirectory(connection: connection, path: path)
                try await uploadContents(connection: connection, localDirectory: url, remoteDirectory: path)
            } else if values.isDirectory != true {
                try await uploadFile(connection: connection, localURL: url, into: remoteDirectory)
            }
        }
    }

    func downloadFile(connection: SSHConnection, item: SftpItem, to localURL: URL) async throws {
        let client = try await client(for: connection)
        try await transfer {
            // Write beside the destination, replacing it only after a successful transfer.
            let temporary = localURL.deletingLastPathComponent().appendingPathComponent(".neolink-\(UUID().uuidString).download")
            let fm = FileManager.default
            guard fm.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? fm.removeItem(at: temporary) }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            let file = try await client.openFile(at: SFTPFilePath(item.path), flags: [.read])
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let data = try await file.read(from: offset, length: 256 * 1024)
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                    offset += UInt64(data.count)
                }
            } catch {
                try? await file.close()
                throw error
            }
            try await file.close()
            try output.synchronize()
            try output.close()
            try Task.checkCancellation()
            if fm.fileExists(atPath: localURL.path) {
                _ = try fm.replaceItemAt(localURL, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: localURL)
            }
        }
    }

    func downloadDirectory(connection: SSHConnection, item: SftpItem, into localDirectoryURL: URL) async throws {
        guard item.isDirectory else { return }
        let targetRoot = localDirectoryURL.appendingPathComponent(item.name, isDirectory: true)
        try createDownloadDirectory(at: targetRoot)
        try await downloadContents(connection: connection, remotePath: item.path, localDirectory: targetRoot)
    }

    private func downloadContents(connection: SSHConnection, remotePath: String, localDirectory: URL) async throws {
        let entries = try await listDirectory(connection: connection, path: remotePath)
        for entry in entries {
            try Task.checkCancellation()
            let destination = localDirectory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try createDownloadDirectory(at: destination)
                try await downloadContents(connection: connection, remotePath: entry.path, localDirectory: destination)
            } else {
                try await downloadFile(connection: connection, item: entry, to: destination)
            }
        }
    }

    private func createDownloadDirectory(at url: URL) throws {
        // An existing symlink inside the destination must not redirect a recursive download.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// File reads and writes stay off the main actor, with bounded memory for large transfers.
    private func transfer(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let task = Task.detached(priority: .utility, operation: body)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
