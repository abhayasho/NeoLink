import Foundation

final class SessionStore {
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("NeoLink", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir.appendingPathComponent("sessions.json")
    }

    func load() -> [Session] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [Session(id: UUID(), name: "Local terminal", type: .local, host: nil, port: nil, username: nil)]
        }
        do {
            return try JSONDecoder().decode([Session].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ sessions: [Session]) {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL)
        } catch {
        }
    }
}

