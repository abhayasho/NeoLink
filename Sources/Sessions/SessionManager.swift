import Foundation

final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Session]
    private let store = SessionStore()

    init() {
        let loaded = store.load()
        self.sessions = loaded.isEmpty ? [Session(id: UUID(), name: "Local terminal", type: .local, host: nil, port: nil, username: nil)] : loaded
    }

    func add(session: Session) {
        sessions.append(session)
        store.save(sessions)
    }

    func update(session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
        store.save(sessions)
    }

    func remove(session: Session) {
        sessions.removeAll { $0.id == session.id }
        store.save(sessions)
    }
}

