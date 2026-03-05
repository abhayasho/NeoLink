import Foundation

@MainActor
final class SftpConnectionPool: ObservableObject {
    private var holders: [String: SftpConnectionHolder] = [:]

    func holder(host: String, port: Int, username: String) -> SftpConnectionHolder {
        let key = "\(host):\(port):\(username)"
        if let existing = holders[key] { return existing }
        let h = SftpConnectionHolder(host: host, port: port, username: username)
        holders[key] = h
        return h
    }
}
