import Foundation
import SSHClient

@MainActor
final class SftpManager {
    static let shared = SftpManager()
    private init() {}

    // MARK: - Directory listing

    func listDirectory(connection: SSHConnection, path: String) async throws -> [SftpItem] {
        let client = try await connection.requestSFTPClient()
        let entries = try await withCheckedThrowingContinuation { continuation in
            client.listDirectory(at: SFTPFilePath(path)) { result in
                continuation.resume(with: result)
            }
        }

        return entries.compactMap { entry -> SftpItem? in
            let name = entry.filename.string
            if name == "." || name == ".." { return nil }

            let fullPath = path.hasSuffix("/") ? (path + name) : (path + "/" + name)
            let attributes = entry.attributes
            let isDirectory = entry.longname.first == "d"

            return SftpItem(
                path: fullPath,
                name: name,
                isDirectory: isDirectory,
                size: attributes.size,
                modifiedAt: attributes.accessModificationTime?.modificationTime
            )
        }
    }

    // MARK: - Mutating operations

    func createDirectory(connection: SSHConnection, path: String) async throws {
        let client = try await connection.requestSFTPClient()
        try await withCheckedThrowingContinuation { continuation in
            client.createDirectory(at: SFTPFilePath(path)) { result in
                continuation.resume(with: result)
            }
        }
    }

    func delete(item: SftpItem, connection: SSHConnection) async throws {
        let client = try await connection.requestSFTPClient()
        let path = SFTPFilePath(item.path)
        try await withCheckedThrowingContinuation { continuation in
            if item.isDirectory {
                client.removeDirectory(at: path) { result in
                    continuation.resume(with: result)
                }
            } else {
                client.removeFile(at: path) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    func rename(item: SftpItem, to newName: String, connection: SSHConnection) async throws {
        let client = try await connection.requestSFTPClient()
        let current = SFTPFilePath(item.path)
        let parent: String
        if let range = item.path.range(of: "/", options: .backwards) {
            parent = String(item.path[..<range.lowerBound])
        } else {
            parent = "."
        }
        let destinationPath = parent == "." ? newName : parent + "/" + newName
        let destination = SFTPFilePath(destinationPath)
        try await withCheckedThrowingContinuation { continuation in
            client.moveItem(at: current, to: destination) { result in
                continuation.resume(with: result)
            }
        }
    }

    // Upload a local file into the given remote directory.
    func uploadFile(connection: SSHConnection, localURL: URL, into remoteDirectory: String) async throws {
        let client = try await connection.requestSFTPClient()
        let data = try Data(contentsOf: localURL)
        let remotePath: String
        if remoteDirectory == "." {
            remotePath = localURL.lastPathComponent
        } else if remoteDirectory.hasSuffix("/") {
            remotePath = remoteDirectory + localURL.lastPathComponent
        } else {
            remotePath = remoteDirectory + "/" + localURL.lastPathComponent
        }

        try await withCheckedThrowingContinuation { continuation in
            client.withFile(
                at: SFTPFilePath(remotePath),
                flags: [.create, .write, .truncate]
            ) { file, close in
                file.write(data, at: 0) { result in
                    switch result {
                    case .success:
                        close()
                    case .failure(let error):
                        close()
                        continuation.resume(throwing: error)
                    }
                }
            } completion: { result in
                continuation.resume(with: result)
            }
        }
    }

    // Upload a local directory recursively into the given remote directory.
    // Creates remote directories as needed.
    func uploadDirectory(connection: SSHConnection, localDirectoryURL: URL, into remoteDirectory: String) async throws {
        let fm = FileManager.default
        let baseName = localDirectoryURL.lastPathComponent
        let targetRoot: String
        if remoteDirectory == "." {
            targetRoot = baseName
        } else if remoteDirectory.hasSuffix("/") {
            targetRoot = remoteDirectory + baseName
        } else {
            targetRoot = remoteDirectory + "/" + baseName
        }

        // Create root folder (ignore failure if it already exists)
        try? await createDirectory(connection: connection, path: targetRoot)

        guard let enumerator = fm.enumerator(at: localDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for case let url as URL in enumerator {
            let relPath = url.path.replacingOccurrences(of: localDirectoryURL.path + "/", with: "")
            let remotePath = targetRoot + "/" + relPath
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? await createDirectory(connection: connection, path: remotePath)
            } else {
                try await uploadFile(connection: connection, localURL: url, into: remotePath.deletingLastPathComponentString)
            }
        }
    }

    // Download a remote file into the given local URL (overwriting if needed).
    func downloadFile(connection: SSHConnection, item: SftpItem, to localURL: URL) async throws {
        let client = try await connection.requestSFTPClient()
        try await withCheckedThrowingContinuation { continuation in
            client.withFile(at: SFTPFilePath(item.path), flags: [.read]) { file, close in
                file.read(from: 0, length: .max) { result in
                    switch result {
                    case .success(let data):
                        do {
                            if FileManager.default.fileExists(atPath: localURL.path) {
                                try FileManager.default.removeItem(at: localURL)
                            }
                            try data.write(to: localURL)
                            close()
                        } catch {
                            close()
                            continuation.resume(throwing: error)
                            return
                        }
                    case .failure(let error):
                        close()
                        continuation.resume(throwing: error)
                        return
                    }
                }
            } completion: { result in
                continuation.resume(with: result)
            }
        }
    }

    // Download a remote directory recursively into the given local directory.
    // Creates local directories as needed.
    func downloadDirectory(connection: SSHConnection, item: SftpItem, into localDirectoryURL: URL) async throws {
        guard item.isDirectory else { return }
        let fm = FileManager.default
        let targetRoot = localDirectoryURL.appendingPathComponent(item.name, isDirectory: true)
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        try await downloadDirectoryRecursive(connection: connection, remotePath: item.path, into: targetRoot)
    }

    private func downloadDirectoryRecursive(connection: SSHConnection, remotePath: String, into localDir: URL) async throws {
        let fm = FileManager.default
        let entries = try await listDirectory(connection: connection, path: remotePath)
        for entry in entries {
            if entry.isDirectory {
                let nextLocal = localDir.appendingPathComponent(entry.name, isDirectory: true)
                try fm.createDirectory(at: nextLocal, withIntermediateDirectories: true)
                try await downloadDirectoryRecursive(connection: connection, remotePath: entry.path, into: nextLocal)
            } else {
                let dest = localDir.appendingPathComponent(entry.name, isDirectory: false)
                try await downloadFile(connection: connection, item: entry, to: dest)
            }
        }
    }
}

private extension String {
    var deletingLastPathComponentString: String {
        if self == "." || self == "/" { return self }
        if let range = self.range(of: "/", options: .backwards) {
            let parent = String(self[..<range.lowerBound])
            return parent.isEmpty ? "." : parent
        }
        return "."
    }
}

