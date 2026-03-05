import Foundation

enum RemoteDesktopType: String, Codable {
    case rdp
    case vnc
}

struct RemoteDesktopSession: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: RemoteDesktopType
    var host: String
    var port: Int
}

