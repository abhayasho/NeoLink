import Foundation
import SSHClient

@MainActor
final class SftpConnectionHolder: ObservableObject {
    @Published private(set) var connection: SSHConnection?
    @Published private(set) var isConnecting = false
    @Published var lastError: String?
    @Published private(set) var connectionState: SSHConnection.State = .idle

    let host: String
    let port: Int
    let username: String
    let browser = SftpBrowserViewModel()

    private var pendingConnection: SSHConnection?
    private var attemptID = UUID()

    init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// Keep the callback API here: SSHClient's connection startup predates Swift concurrency.
    func connect(password: String) {
        guard connection == nil, !isConnecting else { return }
        guard let sshPort = UInt16(exactly: port), sshPort > 0 else {
            lastError = "The SSH port must be between 1 and 65535."
            return
        }
        let attempt = UUID()
        attemptID = attempt
        isConnecting = true
        lastError = nil

        let auth = SSHAuthentication(
            username: username,
            method: .password(.init(password)),
            hostKeyValidation: .acceptAll()
        )
        let conn = SSHConnection(host: host, port: sshPort, authentication: auth, defaultTimeout: 30)
        pendingConnection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, let conn, self.attemptID == attempt else { return }
                self.connectionState = state
                if case .failed(let error) = state {
                    self.attemptID = UUID()
                    self.lastError = error.localizedDescription
                    self.connection = nil
                    self.pendingConnection = nil
                    self.isConnecting = false
                    SftpManager.shared.release(connection: conn)
                    conn.cancel {}
                } else if state == .idle, self.connection != nil {
                    self.connection = nil
                    SftpManager.shared.release(connection: conn)
                }
            }
        }

        conn.start(withTimeout: nil) { [weak self] result in
            Task { @MainActor in
                guard let self, self.attemptID == attempt else { return }
                self.isConnecting = false
                self.pendingConnection = nil
                switch result {
                case .success:
                    self.connection = conn
                    self.connectionState = .ready
                    KeychainSSHPassword.set(host: self.host, port: self.port, username: self.username, password: password)
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    conn.cancel {}
                }
            }
        }
    }

    func tryAutoConnect() {
        guard connection == nil, !isConnecting, lastError == nil else { return }
        guard let password = KeychainSSHPassword.get(host: host, port: port, username: username) else { return }
        connect(password: password)
    }

    func disconnect() {
        attemptID = UUID() // Ignore late startup/state callbacks from the cancelled connection.
        let conn = connection ?? pendingConnection
        connection = nil
        pendingConnection = nil
        isConnecting = false
        connectionState = .idle
        browser.reset()
        if let conn {
            SftpManager.shared.release(connection: conn)
            conn.cancel {}
        }
    }
}
