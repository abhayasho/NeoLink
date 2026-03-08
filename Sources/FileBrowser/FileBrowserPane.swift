import SwiftUI

struct FileBrowserPane: View {
    let backend: TerminalBackend
    @ObservedObject var terminalState: TerminalState
    @EnvironmentObject private var sftpConnectionPool: SftpConnectionPool

    @StateObject private var localVM = LocalFileBrowserViewModel()
    @StateObject private var remoteVM = SftpBrowserViewModel()

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NeoLinkTheme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 2)

            NeoLinkTheme.horizontalSeparator()

            Group {
                switch backend {
                case .localShell:
                    if let (username, host) = parseSSHTitle(terminalState.terminalTitle) {
                        SftpPaneContent(
                            tabHost: host,
                            tabUsername: username,
                            tabPort: 22,
                            pool: sftpConnectionPool,
                            viewModel: remoteVM,
                            detectedHint: "\(username)@\(host)"
                        )
                    } else {
                        LocalFileBrowserView(viewModel: localVM, terminalState: terminalState)
                            .onAppear(perform: syncLocalToTerminalDirectory)
                            .onChange(of: terminalState.currentDirectory ?? "") { _ in
                                syncLocalToTerminalDirectory()
                            }
                    }
                case .ssh(let host, let username, let port):
                    SftpPaneContent(
                        tabHost: host,
                        tabUsername: username,
                        tabPort: port,
                        pool: sftpConnectionPool,
                        viewModel: remoteVM,
                        detectedHint: nil
                    )
                }
            }
        }
        .padding(6)
        .background(NeoLinkTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var title: String {
        switch backend {
        case .localShell:
            return terminalState.terminalTitle.flatMap { parseSSHTitle($0) } != nil ? "Remote files (SFTP)" : "Local files"
        case .ssh:
            return "Remote files (SFTP)"
        }
    }

    private func syncLocalToTerminalDirectory() {
        guard let path = terminalState.currentDirectory, !path.isEmpty else { return }
        localVM.syncTo(path: path)
    }
}

/// Parses terminal title set by SSH (e.g. "user@host", "user@login-ice-2", "user@login-ice-3:~") into (username, host).
/// Strips any ":path" suffix from the host (e.g. ":~" or ":/path") so we connect to the hostname only.
private func parseSSHTitle(_ title: String?) -> (String, String)? {
    guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    let parts = t.split(separator: "@", maxSplits: 1)
    if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
        var hostPart = String(parts[1])
        if let colon = hostPart.firstIndex(of: ":") {
            hostPart = String(hostPart[..<colon])
        }
        if hostPart.isEmpty { return nil }
        let host = hostForSFTP(parsedHost: hostPart)
        return (String(parts[0]), host)
    }
    return nil
}

/// Use full hostname when the server reports a short name (e.g. login-ice-3 → login-ice.pace.gatech.edu) so SFTP can resolve.
private func hostForSFTP(parsedHost: String) -> String {
    if parsedHost.hasPrefix("login-ice-") {
        return "login-ice.pace.gatech.edu"
    }
    return parsedHost
}

// MARK: - SSH/SFTP pane: password-only when host/user are known or detected from terminal
private struct SftpPaneContent: View {
    let tabHost: String
    let tabUsername: String
    let tabPort: Int
    @ObservedObject var pool: SftpConnectionPool
    @ObservedObject var viewModel: SftpBrowserViewModel
    let detectedHint: String?  // e.g. "aashok45@login-ice-2" when detected from terminal title; nil when from SSH tab

    @State private var password = ""

    private var holder: SftpConnectionHolder {
        pool.holder(host: tabHost, port: tabPort, username: tabUsername)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if holder.connection != nil {
                SftpBrowserView(viewModel: viewModel, connection: holder.connection!)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let hint = detectedHint {
                        Text("SSH session detected from terminal: \(hint)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Enter password to load remote files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("\(tabUsername)@\(tabHost):\(tabPort)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if let err = holder.lastError {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    Button(holder.isConnecting ? "Connecting…" : "Connect") {
                        holder.connect(password: password)
                    }
                    .disabled(holder.isConnecting || password.isEmpty)
                }
                .padding(4)
                .onAppear {
                    holder.tryAutoConnect()
                }
            }
        }
    }

}

