import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var tabsController: TabsController
    @State private var sessionToEdit: Session?
    @State private var search = ""

    private var savedSessions: [Session] {
        sessionManager.sessions.filter {
            $0.type == .ssh && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || ($0.host ?? "").localizedCaseInsensitiveContains(search)
                || ($0.username ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(NeoLinkTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(NeoLinkTheme.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("NeoLink").font(.system(size: 17, weight: .semibold))
                    Text("Your connections, together")
                        .font(.system(size: 10))
                        .foregroundStyle(NeoLinkTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)

            Button { tabsController.openLocalTab() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "terminal")
                        .foregroundStyle(NeoLinkTheme.accent)
                    Text("Local terminal").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌘T").font(.system(size: 10)).foregroundStyle(NeoLinkTheme.textSecondary)
                }
                .padding(11)
                .background(NeoLinkTheme.elevated.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("Open a local shell")

            HStack {
                Text("CONNECTIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                Spacer()
                Button(action: newSSHSession) { Image(systemName: "plus") }
                    .buttonStyle(WorkspaceIconButtonStyle())
                    .help("New SSH connection (⇧⌘N)")
                    .accessibilityLabel("New SSH connection")
            }
            .foregroundStyle(NeoLinkTheme.textSecondary)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.top, 22)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField("Find a connection", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("Find a connection")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear connection search")
                }
            }
            .foregroundStyle(NeoLinkTheme.textSecondary)
            .padding(9)
            .background(NeoLinkTheme.editorBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(savedSessions) { session in
                        sessionRow(session)
                    }
                    if savedSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: search.isEmpty ? "network" : "magnifyingglass")
                                .font(.system(size: 20))
                            Text(search.isEmpty ? "Add your first connection" : "No matching connections")
                                .font(.system(size: 12, weight: .medium))
                            Text(search.isEmpty ? "Save an SSH host to open a terminal and browse its files." : "Try a different name or hostname.")
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                            if search.isEmpty {
                                Button("Add connection", action: newSSHSession)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(NeoLinkTheme.accent)
                                    .buttonStyle(.plain)
                            }
                        }
                        .foregroundStyle(NeoLinkTheme.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            NeoLinkTheme.horizontalSeparator()
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                Text(Host.current().localizedName ?? "This Mac").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(NeoLinkTheme.textSecondary)
            .padding(14)
        }
        .foregroundStyle(NeoLinkTheme.textPrimary)
        .frame(maxHeight: .infinity)
        .background(NeoLinkTheme.sidebarBackground)
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewSSHSession)) { _ in newSSHSession() }
        .sheet(item: $sessionToEdit) { session in
            SessionEditSheet(
                session: session,
                isNew: !sessionManager.sessions.contains(where: { $0.id == session.id }),
                onSave: { updated in
                    if sessionManager.sessions.contains(where: { $0.id == updated.id }) {
                        sessionManager.update(session: updated)
                    } else {
                        sessionManager.add(session: updated)
                    }
                    sessionToEdit = nil
                },
                onCancel: { sessionToEdit = nil }
            )
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        let isSelected = tabsController.selectedTab.map { tab in
            tab.configuration.backend == .ssh(host: session.host ?? "", username: session.username ?? NSUserName(), port: session.port ?? 22)
        } ?? false
        return Button { open(session: session) } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name).font(.system(size: 12, weight: .medium))
                    Text("\(session.username ?? NSUserName())@\(session.host ?? "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NeoLinkTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Circle().fill(NeoLinkTheme.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(isSelected ? NeoLinkTheme.selectionBlue : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(session.name)")
        .contextMenu {
            Button("Open in new tab") { open(session: session) }
            Button("Edit connection…") {
                sessionToEdit = session
            }
            Divider()
            Button("Remove connection", role: .destructive) { sessionManager.remove(session: session) }
        }
    }

    private func newSSHSession() {
        sessionToEdit = Session(id: UUID(), name: "", type: .ssh, host: "", port: 22, username: NSUserName())
    }

    private func open(session: Session) {
        switch session.type {
        case .local:
            tabsController.openLocalTab()
        case .ssh:
            guard let host = session.host, !host.isEmpty else { return }
            let configuration = TerminalConfiguration(backend: .ssh(host: host, username: session.username ?? NSUserName(), port: session.port ?? 22))
            tabsController.openTab(title: session.name, configuration: configuration)
        }
    }
}

struct SessionEditSheet: View {
    let session: Session
    var isNew = false
    let onSave: (Session) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var portStr = "22"
    @State private var username = ""
    @FocusState private var nameFocused: Bool

    private var validInput: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (session.type != .ssh || SSHSessionInput.isValid(host: host, username: username, port: portStr))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 24))
                    .foregroundStyle(NeoLinkTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "New connection" : "Edit connection")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Keep a remote workspace one click away.")
                        .font(.system(size: 12))
                        .foregroundStyle(NeoLinkTheme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Connection name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NeoLinkTheme.textSecondary)
                TextField("My server", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Connection name")
                    .focused($nameFocused)
            }
            if session.type == .ssh {
                field("Hostname", placeholder: "server.example.com", text: $host)
                HStack(alignment: .top, spacing: 12) {
                    field("Username", placeholder: "username", text: $username)
                    field("Port", placeholder: "22", text: $portStr).frame(width: 90)
                }
                if !portStr.isEmpty && !(Int(portStr).map { (1...65535).contains($0) } ?? false) {
                    Text("Enter a port between 1 and 65535.")
                        .font(.caption)
                        .foregroundStyle(NeoLinkTheme.warning)
                }
            }
            NeoLinkTheme.horizontalSeparator()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Save connection" : "Save changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(NeoLinkTheme.accent)
                    .foregroundStyle(NeoLinkTheme.editorBackground)
                    .disabled(!validInput)
            }
        }
        .padding(28)
        .frame(width: 420)
        .background(NeoLinkTheme.sidebarBackground)
        .onAppear {
            name = session.name
            host = session.host ?? ""
            portStr = session.port.map(String.init) ?? "22"
            username = session.username ?? NSUserName()
            nameFocused = true
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(NeoLinkTheme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func save() {
        guard validInput else { return }
        var updated = session
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.type == .ssh {
            updated.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.port = Int(portStr)
            updated.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        onSave(updated)
    }
}

/// Accept hostnames, SSH aliases and IPv6 addresses, but never command options or whitespace.
enum SSHSessionInput {
    static func isValid(host: String, username: String, port: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains("@"),
              host.rangeOfCharacter(from: forbidden) == nil,
              !username.isEmpty, !username.hasPrefix("-"), !username.contains("@"),
              username.rangeOfCharacter(from: forbidden) == nil,
              let port = Int(port), (1...65535).contains(port) else { return false }
        return true
    }
}
