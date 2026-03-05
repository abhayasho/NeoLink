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
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)

                Divider()

                TabbedTerminalView(controller: tabsController, terminalState: terminalState)
                    .padding(.leading, 4)
            }
        }
        .environmentObject(sessionManager)
        .environmentObject(tabsController)
        .environmentObject(sftpConnectionPool)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
    }
}

