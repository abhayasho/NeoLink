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
}

