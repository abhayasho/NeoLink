import Foundation
import SSHClient

@MainActor
final class SftpConnectionHolder: ObservableObject {
    @Published private(set) var connection: SSHConnection?
    @Published private(set) var isConnecting = false
    @Published var lastError: String?
    @Published var connectionState: SSHConnection.State = .idle

    let host: String
    let port: Int
    let username: String

    init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// Starts an SFTP-capable SSH connection using the given password.
    /// This uses callback-based APIs (no async/await) to avoid Swift 6
    /// concurrency assertions inside the SSHClient library.
    func connect(password: String) {
        guard connection == nil, !isConnecting else { return }
        isConnecting = true
        lastError = nil

        let auth = SSHAuthentication(
            username: username,
            method: .password(.init(password)),
            hostKeyValidation: .acceptAll()
        )
        let conn = SSHConnection(
            host: host,
            port: UInt16(port),
            authentication: auth,
            defaultTimeout: 30
        )

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
            }
        }

        conn.start(withTimeout: nil) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isConnecting = false
                switch result {
                case .success:
                    self.connection = conn
                    KeychainSSHPassword.set(
                        host: self.host,
                        port: self.port,
                        username: self.username,
                        password: password
                    )
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Connects using password from keychain if available (no prompt). Call on appear to auto-connect.
    func tryAutoConnect() {
        guard connection == nil, !isConnecting else { return }
        guard let password = KeychainSSHPassword.get(host: host, port: port, username: username) else { return }
        connect(password: password)
    }

    func disconnect() {
        guard let conn = connection else { return }
        connection = nil
        connectionState = .idle
        conn.cancel { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.connectionState = .idle
            }
        }
    }
}
