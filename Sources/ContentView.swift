import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var tabsController = TabsController()
    @StateObject private var sftpConnectionPool = SftpConnectionPool()
    @StateObject private var fileBrowsers = WorkspaceFileBrowsers()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("showFileBrowser") private var showFileBrowser = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                NeoLinkTheme.horizontalSeparator()
                HSplitView {
                    if showFileBrowser, let tab = tabsController.selectedTab {
                        FileBrowserPane(backend: tab.configuration.backend, terminalState: tab.state, localVM: fileBrowsers.browser(for: tab))
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
        .environmentObject(sessionManager)
        .environmentObject(tabsController)
        .environmentObject(sftpConnectionPool)
        .tint(NeoLinkTheme.accent)
        .preferredColorScheme(.dark)
        .font(NeoLinkTheme.font)
        .background(NeoLinkTheme.background)
        .onChange(of: tabsController.tabs.map(\.id)) { ids in
            fileBrowsers.retainTabs(Set(ids))
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNewTab)) { _ in
            tabsController.openLocalTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkCloseTab)) { _ in
            if let id = tabsController.selectedTabID { tabsController.closeTab(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkNextTab)) { _ in selectTab(offset: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkPreviousTab)) { _ in selectTab(offset: -1) }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleFiles)) { _ in showFileBrowser.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .neoLinkToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(NeoLinkTheme.accent)
            Text("Workspace")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NeoLinkTheme.textPrimary)
            Text("/  \(tabsController.selectedTab?.title ?? "Terminal")")
                .font(.system(size: 12))
                .foregroundStyle(NeoLinkTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button { showFileBrowser.toggle() } label: {
                Image(systemName: "sidebar.left")
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
        .background(NeoLinkTheme.sidebarBackground)
    }

    private var workspaceFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "command")
                .foregroundStyle(NeoLinkTheme.accent)
            Text("Ready for your next command")
            Spacer()
            Text("\(tabsController.tabs.count) \(tabsController.tabs.count == 1 ? "terminal" : "terminals")")
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
        guard let current = tabsController.tabs.firstIndex(where: { $0.id == tabsController.selectedTabID }),
              !tabsController.tabs.isEmpty else { return }
        let count = tabsController.tabs.count
        tabsController.selectedTabID = tabsController.tabs[(current + offset + count) % count].id
    }
}
