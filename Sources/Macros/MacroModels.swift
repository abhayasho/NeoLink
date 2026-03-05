import Foundation

struct Macro: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var keystrokes: Data
}

