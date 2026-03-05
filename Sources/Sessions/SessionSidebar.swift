import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var tabsController: TabsController
    @State private var sessionToEdit: Session?

    var body: some View {
        List {
            Section("Saved sessions") {
                ForEach(sessionManager.sessions) { session in
                    Button {
                        open(session: session)
                    } label: {
                        Text(session.name)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if session.type == .ssh {
                            Button("Edit session…") {
                                sessionToEdit = session
                            }
                        }
                        if session.type != .local {
                            Button("Remove", role: .destructive) {
                                sessionManager.remove(session: session)
                            }
                        }
                    }
                }
            }

            Section("Quick actions") {
                Button("New local tab") {
                    tabsController.openLocalTab()
                }

                Button("SSH") {
                    let s = Session(
                        id: UUID(),
                        name: "SSH",
                        type: .ssh,
                        host: "example.com",
                        port: 22,
                        username: NSUserName()
                    )
                    sessionManager.add(session: s)
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $sessionToEdit) { session in
            SessionEditSheet(
                session: session,
                onSave: { updated in
                    sessionManager.update(session: updated)
                    sessionToEdit = nil
                },
                onCancel: { sessionToEdit = nil }
            )
        }
    }

    private func open(session: Session) {
        switch session.type {
        case .local:
            tabsController.openLocalTab()
        case .ssh:
            let host = session.host ?? ""
            let user = session.username ?? NSUserName()
            let port = session.port ?? 22
            let configuration = TerminalConfiguration(backend: .ssh(host: host, username: user, port: port))
            tabsController.openTab(title: session.name, configuration: configuration)
        }
    }
}

// MARK: - Session edit sheet (so File GUI and terminal use the same host)
struct SessionEditSheet: View {
    let session: Session
    let onSave: (Session) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portStr: String = "22"
    @State private var username: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit session")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            if session.type == .ssh {
                TextField("Host (e.g. login-ice.pace.gatech.edu)", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $portStr)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel", action: onCancel)
                Button("Save") {
                    var updated = session
                    updated.name = name
                    if session.type == .ssh {
                        updated.host = host.isEmpty ? nil : host
                        updated.port = Int(portStr).flatMap { $0 > 0 ? $0 : nil } ?? 22
                        updated.username = username.isEmpty ? nil : username
                    }
                    onSave(updated)
                }
                .disabled(name.isEmpty || (session.type == .ssh && host.isEmpty))
            }
        }
        .padding(24)
        .frame(minWidth: 320)
        .onAppear {
            name = session.name
            host = session.host ?? ""
            portStr = session.port.map { String($0) } ?? "22"
            username = session.username ?? NSUserName()
        }
    }
}

