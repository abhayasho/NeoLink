import Foundation

struct SftpItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?
}

/// Remote paths are POSIX paths, independent of the local computer's file system.
enum RemotePath {
    static func appending(_ name: String, to directory: String) -> String {
        if directory == "." || directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        if path == "/" { return "/" }
        if path == "." || path.isEmpty { return ".." }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == ".." || trimmed.hasSuffix("/..") { return trimmed + "/.." }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
