import Foundation

@MainActor
final class SftpConnectionPool: ObservableObject {
    private struct Endpoint: Hashable {
        let host: String
        let port: Int
        let username: String
    }

    private var holders: [Endpoint: SftpConnectionHolder] = [:]

    func holder(host: String, port: Int, username: String) -> SftpConnectionHolder {
        let key = Endpoint(host: host, port: port, username: username)
        if let existing = holders[key] { return existing }
        let holder = SftpConnectionHolder(host: host, port: port, username: username)
        holders[key] = holder
        return holder
    }
}
