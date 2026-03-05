import Foundation

struct SftpItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?
}

