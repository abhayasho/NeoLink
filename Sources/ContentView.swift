import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var tabsController = TabsController()
    @StateObject private var terminalState = TerminalState()
    @StateObject private var sftpConnectionPool = SftpConnectionPool()

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
        } detail: {
            HStack(spacing: 0) {
                let backend = tabsController.selectedTab?.configuration.backend ?? .localShell

                FileBrowserPane(backend: backend, terminalState: terminalState)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

                NeoLinkTheme.verticalSeparator()

                TabbedTerminalView(controller: tabsController, terminalState: terminalState)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(NeoLinkTheme.background)
            .overlay(alignment: .leading) {
                NeoLinkTheme.verticalSeparator()
            }
        }
        .environmentObject(sessionManager)
        .environmentObject(tabsController)
        .environmentObject(sftpConnectionPool)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        .tint(NeoLinkTheme.accent)
        .environment(\.colorScheme, .dark)
        .font(NeoLinkTheme.font)
        .background(NeoLinkTheme.background)
    }
}

