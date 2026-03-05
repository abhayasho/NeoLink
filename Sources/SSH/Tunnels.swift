import Foundation

enum PortForwardType: String, Codable {
    case local
    case remote
    case dynamic
}

struct PortForwardRule: Identifiable, Codable, Equatable {
    let id: UUID
    var type: PortForwardType
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
}

