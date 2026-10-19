import SwiftUI

struct FileBrowserPane: View {
    let backend: TerminalBackend
    @ObservedObject var terminalState: TerminalState
    @EnvironmentObject private var sftpConnectionPool: SftpConnectionPool

    @ObservedObject var localVM: LocalFileBrowserViewModel

    private var remoteEndpoint: (username: String, host: String, port: Int)? {
        switch backend {
        case .localShell:
            guard let endpoint = DetectedSSHEndpoint.parse(terminalState.terminalTitle) else { return nil }
            return (endpoint.username, endpoint.host, 22)
        case .ssh(let host, let username, let port):
            return (username, host, port)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: remoteEndpoint == nil ? "folder" : "externaldrive.connected.to.line.below")
                    .foregroundColor(NeoLinkTheme.accent)
                Text("Files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NeoLinkTheme.textPrimary)
                Spacer(minLength: 8)
                Text(remoteEndpoint == nil ? "LOCAL" : "SFTP")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(NeoLinkTheme.rowFill, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            NeoLinkTheme.horizontalSeparator()

            Group {
                if let endpoint = remoteEndpoint {
                    SftpPaneContent(
                        holder: sftpConnectionPool.holder(host: endpoint.host, port: endpoint.port, username: endpoint.username),
                        isDetected: backend == .localShell
                    )
                    .id("\(endpoint.username)@\(endpoint.host):\(endpoint.port)")
                } else {
                    LocalFileBrowserView(viewModel: localVM, terminalState: terminalState)
                        .task(id: LocalBrowserSyncKey(terminalID: ObjectIdentifier(terminalState), directory: terminalState.currentDirectory)) {
                            syncLocalToTerminalDirectory()
                        }
                }
            }
            .padding(8)
        }
        .background(NeoLinkTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NeoLinkTheme.panelBorder, lineWidth: 1))
    }

    private func syncLocalToTerminalDirectory() {
        guard let path = terminalState.currentDirectory, !path.isEmpty else { return }
        localVM.syncTo(path: path)
    }
}

private struct LocalBrowserSyncKey: Hashable {
    let terminalID: ObjectIdentifier
    let directory: String?
}

/// Terminal titles are only hints. Never interpret a local shell's user@computer title as SSH.
struct DetectedSSHEndpoint: Equatable {
    let username: String
    let host: String

    static func parse(_ title: String?, localHostnames: Set<String> = defaultLocalHostnames) -> DetectedSSHEndpoint? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let parts = title.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let username = String(parts[0])
        let host = String(parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !username.isEmpty, !host.isEmpty,
              username.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let localNames = Set(localHostnames.map { $0.lowercased() })
        guard normalized != "localhost", normalized != "0.0.0.0", !normalized.hasPrefix("127."),
              !localNames.contains(normalized),
              !localNames.contains(normalized + ".local"),
              !localNames.contains(normalized.replacingOccurrences(of: ".local", with: "")) else { return nil }
        let resolved = normalized.hasPrefix("login-ice-") ? "login-ice.pace.gatech.edu" : host
        return DetectedSSHEndpoint(username: username, host: resolved)
    }

    static let defaultLocalHostnames: Set<String> = {
        var names: Set<String> = [ProcessInfo.processInfo.hostName]
        if let name = Host.current().localizedName { names.insert(name) }
        for name in names {
            if let short = name.split(separator: ".").first { names.insert(String(short)) }
        }
        return names
    }()
}

private struct SftpPaneContent: View {
    @ObservedObject var holder: SftpConnectionHolder
    let isDetected: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(holder.connection == nil ? NeoLinkTheme.textSecondary : NeoLinkTheme.accent)
                    .frame(width: 5, height: 5)
                Text("\(holder.username)@\(holder.host)\(holder.port == 22 ? "" : ":\(holder.port)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(holder.username)@\(holder.host):\(holder.port)")
                Spacer(minLength: 0)
                if holder.connection != nil {
                    Button { holder.disconnect() } label: { Image(systemName: "power") }
                        .buttonStyle(.plain)
                        .foregroundColor(NeoLinkTheme.textSecondary)
                        .help("Disconnect remote files")
                        .accessibilityLabel("Disconnect remote files")
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)

            if let connection = holder.connection {
                SftpBrowserView(viewModel: holder.browser, connection: connection)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "folder.badge.person.crop")
                        .font(.system(size: 27, weight: .light))
                        .foregroundColor(NeoLinkTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your remote workspace")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(NeoLinkTheme.textPrimary)
                        Text(isDetected ? "SSH session detected. Connect to browse and transfer files." : "Connect to browse and transfer files alongside your terminal.")
                            .font(.system(size: 11))
                            .foregroundColor(NeoLinkTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SecureField("SSH password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(holder.isConnecting)
                        .onSubmit(connect)
                    if let error = holder.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button(action: connect) {
                            HStack(spacing: 6) {
                                if holder.isConnecting { ProgressView().controlSize(.small) }
                                Text(holder.isConnecting ? "Connecting…" : "Connect to files")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(holder.isConnecting || password.isEmpty)
                        if holder.isConnecting {
                            Button("Cancel") { holder.disconnect() }
                                .buttonStyle(.borderless)
                        }
                    }
                    Text("Your password is saved securely in Keychain after connecting.")
                        .font(.system(size: 10))
                        .foregroundColor(NeoLinkTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NeoLinkTheme.rowFill, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
        }
        .onAppear { holder.tryAutoConnect() }
        .onChange(of: holder.connection != nil) { connected in
            if connected { password = "" }
        }
    }

    private func connect() {
        guard !password.isEmpty, !holder.isConnecting else { return }
        holder.connect(password: password)
    }
}
