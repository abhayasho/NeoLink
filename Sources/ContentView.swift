import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @ObservedObject var tabsController: TabsController
    @ObservedObject private var access = WorkspaceAccess.shared
    @StateObject private var sftpConnectionPool = SftpConnectionPool()
    @StateObject private var fileBrowsers = WorkspaceFileBrowsers()
    @AppStorage("showConnectionsSidebar") private var showConnectionsSidebar = true
    @AppStorage("showFileBrowser") private var showFileBrowser = true
    @State private var search: SearchPresentation?
    @State private var sessionToEdit: Session?
    private struct SearchPresentation: Identifiable {
        let id = UUID()
        let root: URL
        let contents: Bool
    }

    private var workspaceLayout: some View {
        HSplitView {
            if showConnectionsSidebar {
                SessionSidebar(
                    onClose: { showConnectionsSidebar = false },
                    onNewConnection: newSSHSession,
                    onEditConnection: { sessionToEdit = $0 }
                )
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
            }
            VStack(spacing: 0) {
                workspaceHeader
                NeoLinkTheme.horizontalSeparator()
                HSplitView {
                    if showFileBrowser, let tab = tabsController.browserTab {
                        FileBrowserPane(
                            backend: tab.configuration.backend,
                            terminalState: tab.state,
                            localVM: fileBrowsers.browser(for: tab),
                            onClose: { showFileBrowser = false }
                        )
                            .frame(minWidth: 235, idealWidth: 280, maxWidth: 400)
                    }
                    TabbedTerminalView(controller: tabsController)
                        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                }
                NeoLinkTheme.horizontalSeparator()
                workspaceFooter
            }
            .background(NeoLinkTheme.background)
        }
    }

    private var presentedWorkspace: some View {
        workspaceLayout
        .environmentObject(sessionManager)
        .environmentObject(tabsController)
        .environmentObject(sftpConnectionPool)
        .disabled(tabsController.isConfirmingClose)
        .tint(NeoLinkTheme.accent)
        .preferredColorScheme(.dark)
        .font(NeoLinkTheme.font)
        .background(NeoLinkTheme.background)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $search) { value in
            ProjectSearchSheet(root: value.root, searchContents: value.contents) { url, line in
                tabsController.openFile(url)
                if let line, let document = tabsController.selectedTab?.document {
                    Task { await document.navigate(toLine: line) }
                }
            }
        }
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
        .alert("Project access", isPresented: Binding(get: { access.error != nil }, set: { if !$0 { access.error = nil } })) {
            Button("OK") { access.error = nil }
        } message: { Text(access.error ?? "") }
    }

    var body: some View {
        presentedWorkspace
        .onChange(of: tabsController.tabs.map(\.id)) { ids in
            fileBrowsers.retainTabs(Set(tabsController.terminalTabs.map(\.id)))
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewTab)) { _ in
            tabsController.openLocalTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewSSHSession)) { _ in newSSHSession() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkCloseTab)) { _ in
            if let id = tabsController.selectedTabID { tabsController.requestCloseTab(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkSaveFile)) { _ in
            if let document = tabsController.selectedTab?.document { Task { await document.save() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkOpenProject)) { _ in access.chooseFolder() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkQuickOpen)) { _ in showSearch(contents: false) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkFindInFiles)) { _ in showSearch(contents: true) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkCodeAction)) { notification in
            if let name = notification.object as? String, tabsController.selectedTab?.document?.usesNeovim == true {
                tabsController.codeSession.action(name)
            }
        }
        .onChange(of: access.projectURL) { url in
            if let url, let tab = tabsController.browserTab { fileBrowsers.browser(for: tab).navigate(to: url) }
        }
        .onAppear {
            if let url = access.projectURL, let tab = tabsController.browserTab { fileBrowsers.browser(for: tab).navigate(to: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkOpenFile)) { _ in
            guard !tabsController.isConfirmingClose else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Open in Tab"
            panel.begin { response in
                if response == .OK { panel.urls.forEach(tabsController.openFile) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNextTab)) { _ in selectTab(offset: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkPreviousTab)) { _ in selectTab(offset: -1) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleFiles)) { _ in showFileBrowser.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleSidebar)) { _ in
            showConnectionsSidebar.toggle()
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Open Project…") { access.chooseFolder() }
                ForEach(access.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { access.select(url) }
                }
            } label: { Image(systemName: "folder.badge.gearshape").foregroundStyle(NeoLinkTheme.accent) }
            .menuStyle(.borderlessButton).fixedSize().help("Open project and remember folder access")
            Text(access.projectURL?.lastPathComponent ?? "Workspace")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NeoLinkTheme.textPrimary)
            Text("/  \(tabsController.selectedTab?.title ?? "Terminal")")
                .font(.system(size: 12))
                .foregroundStyle(NeoLinkTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button { showSearch(contents: false) } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Quick Open (⌘P)").accessibilityLabel("Quick Open")
            Button { showSearch(contents: true) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Find in Files (⇧⌘F)").accessibilityLabel("Find in Files")
            Button { showConnectionsSidebar.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(showConnectionsSidebar ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            .help("Toggle connections sidebar (⌃⌘S)")
            .accessibilityLabel(showConnectionsSidebar ? "Hide connections sidebar" : "Show connections sidebar")
            Button { showFileBrowser.toggle() } label: {
                Image(systemName: "folder")
                    .foregroundStyle(showFileBrowser ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            .help("Toggle file browser (⇧⌘E)")
            .accessibilityLabel(showFileBrowser ? "Hide file browser" : "Show file browser")
            Button { tabsController.openLocalTab() } label: {
                Label("New terminal", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NeoLinkTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("New local terminal (⌘T)")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(WindowDragArea())
        .background(NeoLinkTheme.sidebarBackground)
    }

    private var workspaceFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "command")
                .foregroundStyle(NeoLinkTheme.accent)
            Text(tabsController.selectedTab?.document == nil ? "Ready for your next command" : "Files, right in your workspace")
            Spacer()
            Text("\(tabsController.tabs.count) \(tabsController.tabs.count == 1 ? "tab" : "tabs")")
            Rectangle().fill(NeoLinkTheme.separator).frame(width: 1, height: 10)
            Text("⌘T  New tab")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(NeoLinkTheme.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(NeoLinkTheme.sidebarBackground)
    }

    private func selectTab(offset: Int) {
        if offset > 0 { tabsController.selectNextTab() }
        else { tabsController.selectPreviousTab() }
    }

    private func newSSHSession() {
        sessionToEdit = Session(id: UUID(), name: "", type: .ssh, host: "", port: 22, username: NSUserName())
    }

    private func showSearch(contents: Bool) {
        if let root = access.projectURL { search = SearchPresentation(root: root, contents: contents) }
        else { access.chooseFolder { root in search = SearchPresentation(root: root, contents: contents) } }
    }
}
