import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @ObservedObject var tabsController: TabsController
    @ObservedObject private var access = WorkspaceAccess.shared
    @StateObject private var sftpConnectionPool = SftpConnectionPool()
    @StateObject private var fileBrowsers = WorkspaceFileBrowsers()
    @AppStorage("showConnectionsSidebar") private var showConnectionsSidebar = false
    @AppStorage("showFileBrowser") private var showFileBrowser = true
    @AppStorage("showAgentPanel") private var savedAgentPanel = true
    @State private var search: SearchPresentation?
    @State private var sessionToEdit: Session?
    @State private var showAgentLauncher = false
    @State private var gitReview: GitPresentation?
    private struct GitPresentation: Identifiable { let id = UUID(); let root: URL }
    private struct SearchPresentation: Identifiable {
        let id = UUID()
        let root: URL
        let contents: Bool
    }

    private var workspaceLayout: some View {
        VStack(spacing: 0) {
            workspaceHeader
            NeoLinkTheme.horizontalSeparator()
            HSplitView {
                    if showConnectionsSidebar {
                        SessionSidebar(onClose: { showConnectionsSidebar = false }, onNewConnection: newSSHSession,
                                       onEditConnection: { sessionToEdit = $0 })
                            .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
                    } else if showFileBrowser, let tab = tabsController.browserTab {
                        FileBrowserPane(
                            backend: tab.configuration.backend,
                            terminalState: tab.state,
                            localVM: fileBrowsers.browser(for: tab),
                            onClose: { showFileBrowser = false }
                        )
                            .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                    }
                    TabbedTerminalView(controller: tabsController)
                        .frame(minWidth: 380, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    if tabsController.showAgentPanel {
                        AgentPanelView(controller: tabsController, launch: { showAgentLauncher = true })
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
                    }
            }
            NeoLinkTheme.horizontalSeparator()
            workspaceFooter
        }
        .background(NeoLinkTheme.background)
        .background(NeoGPUOverlayState(suspended: search != nil || gitReview != nil))
        // Quick Open / Find in Files and Git review are in-window overlays, not AppKit sheets.
        // A sheet's slide-in animation runs a nested run loop that froze the main thread for
        // about 330 ms on open; an overlay appears on the next frame.
        .overlay { paletteOverlay }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if search != nil || gitReview != nil {
            ZStack {
                // Dimmed backdrop; clicking it closes the overlay.
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { search = nil; gitReview = nil }
                if let value = search {
                    ProjectSearchSheet(root: value.root, searchContents: value.contents, open: { url, line in
                        tabsController.openFile(url)
                        if let line, let document = tabsController.selectedTab?.document {
                            Task { await document.navigate(toLine: line) }
                        }
                    }, onClose: { search = nil })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 30)
                } else if let value = gitReview {
                    GitChangesView(directory: value.root, open: { tabsController.openFile($0) }, prepareMutation: {
                        if tabsController.tabs.contains(where: { $0.document?.usesNeovim == true }), !(await tabsController.codeSession.refresh()) { return false }
                        return !tabsController.tabs.contains(where: { $0.document?.isModified == true || $0.document?.isSaving == true }) && tabsController.codeSession.snapshot?.unnamedModified != true
                    }, didMutate: tabsController.refreshAgentEdits, onClose: { gitReview = nil })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 30)
                }
            }
            .transition(.opacity)
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
        .sheet(isPresented: $showAgentLauncher) {
            AgentLauncherView(controller: tabsController, directory: access.projectURL)
        }
        .alert("Project access", isPresented: Binding(get: { access.error != nil }, set: { if !$0 { access.error = nil } })) {
            Button("OK") { access.error = nil }
        } message: { Text(access.error ?? "") }
    }

    private var workspaceWithTabCommands: some View {
        presentedWorkspace
        .onChange(of: tabsController.showAgentPanel) { savedAgentPanel = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleAgentPanel)) { _ in tabsController.showAgentPanel.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkOpenAgent)) { _ in showAgentLauncher = true }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkShowGit)) { notification in
            if let root = notification.object as? URL { gitReview = GitPresentation(root: root) }
            else { showGit() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkOpenREPL)) { notification in
            if let executable = notification.object as? String {
                tabsController.openREPL(executable, in: access.projectURL ?? FileManager.default.homeDirectoryForCurrentUser)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkTextSize)) { notification in
            let delta = notification.object as? Int ?? 0
            if let pdf = tabsController.selectedTab?.document?.pdfView, !(NSApp.keyWindow?.firstResponder is InteractiveTerminalView) {
                if delta == 0 { pdf.autoScales = true }
                else if delta > 0 { pdf.zoomIn(nil) }
                else { pdf.zoomOut(nil) }
            } else if delta == 0 { TextSizePreferences.shared.reset() }
            else { TextSizePreferences.shared.adjust(by: CGFloat(delta)) }
        }
        .onChange(of: tabsController.fileRefreshRevision) { _ in
            if let tab = tabsController.browserTab, tab.configuration.backend == .localShell {
                fileBrowsers.browser(for: tab).load()
            }
        }
        .onChange(of: tabsController.tabs.map(\.id)) { ids in
            fileBrowsers.retainTabs(Set(tabsController.terminalTabs.map(\.id)))
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewTab)) { _ in
            tabsController.openLocalTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewSSHSession)) { _ in newSSHSession() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkCloseTab)) { _ in
            if tabsController.showAgentPanel, let id = tabsController.focusedACPID,
               id == tabsController.selectedACPID, NSApp.keyWindow?.firstResponder is NSTextView {
                tabsController.closeACP(id)
                return
            }
            let focusedAgent = tabsController.agentPanelTabs.first { $0.state.containsResponder(NSApp.keyWindow?.firstResponder) }
            if let id = focusedAgent?.id ?? tabsController.selectedTabID { tabsController.requestCloseTab(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkSaveFile)) { _ in
            if let document = tabsController.selectedTab?.document { Task { await document.save() } }
        }
    }

    var body: some View {
        workspaceWithTabCommands
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
            tabsController.showAgentPanel = savedAgentPanel
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
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleFiles)) { _ in toggleFiles() }
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NeoLinkTheme.textPrimary)
            Spacer()
            Button { showAgentLauncher = true } label: {
                Label("Agent", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless).foregroundStyle(NeoLinkTheme.textPrimary)
            .help("Launch a coding agent (⌃⌘A)").accessibilityLabel("Launch coding agent")
            Button { showSearch(contents: false) } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Quick Open (⌘P)").accessibilityLabel("Quick Open")
            Button { showSearch(contents: true) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Find in Files (⇧⌘F)").accessibilityLabel("Find in Files")
            Button(action: showGit) { Image(systemName: "arrow.triangle.branch") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Source Control (⇧⌘G)").accessibilityLabel("Source Control")
            Button { showConnectionsSidebar.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(showConnectionsSidebar ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            .help("Toggle connections sidebar (⌃⌘S)")
            .accessibilityLabel(showConnectionsSidebar ? "Hide connections sidebar" : "Show connections sidebar")
            Button { toggleFiles() } label: {
                Image(systemName: "folder")
                    .foregroundStyle(showFileBrowser ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            .help("Toggle file browser (⇧⌘E)")
            .accessibilityLabel(showFileBrowser ? "Hide file browser" : "Show file browser")
            Button { tabsController.showAgentPanel.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(WorkspaceIconButtonStyle()).help("Toggle agent panel (⌃⌘B)")
                .accessibilityLabel("Toggle agent panel")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(WindowDragArea())
        .background(NeoLinkTheme.sidebarBackground)
    }

    private var workspaceFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: tabsController.selectedTab?.document == nil ? "terminal" : "doc.text")
            Text(tabsController.selectedTab?.document?.title ?? "NeoLink")
            Spacer()
            Text("\(tabsController.tabs.count) \(tabsController.tabs.count == 1 ? "tab" : "tabs")")
            Rectangle().fill(NeoLinkTheme.separator).frame(width: 1, height: 10)
            Text("⌘T  New tab")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(NeoLinkTheme.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 22)
        .background(NeoLinkTheme.sidebarBackground)
    }

    private func selectTab(offset: Int) {
        if offset > 0 { tabsController.selectNextTab() }
        else { tabsController.selectPreviousTab() }
    }

    private func toggleFiles() {
        if showConnectionsSidebar { showConnectionsSidebar = false; showFileBrowser = true }
        else { showFileBrowser.toggle() }
    }

    private func showGit() {
        if let root = access.projectURL { gitReview = GitPresentation(root: root) }
        else { access.chooseFolder { root in gitReview = GitPresentation(root: root) } }
    }

    private func newSSHSession() {
        sessionToEdit = Session(id: UUID(), name: "", type: .ssh, host: "", port: 22, username: NSUserName())
    }

    private func showSearch(contents: Bool) {
        if let root = access.projectURL { search = SearchPresentation(root: root, contents: contents) }
        else { access.chooseFolder { root in search = SearchPresentation(root: root, contents: contents) } }
    }
}
