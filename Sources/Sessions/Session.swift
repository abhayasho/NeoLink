import Foundation

enum SessionType: String, Codable {
    case local
    case ssh
}

struct Session: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: SessionType

    var host: String?
    var port: Int?
    var username: String?
}

