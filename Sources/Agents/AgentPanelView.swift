import SwiftUI

struct AgentPanelView: View {
    @ObservedObject var controller: TabsController
    let launch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left").foregroundStyle(NeoLinkTheme.textSecondary)
                Text("Agent").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: launch) { Image(systemName: "plus") }
                    .help("New agent session").accessibilityLabel("New agent session")
                Button { controller.showAgentPanel = false } label: { Image(systemName: "sidebar.right") }
                    .help("Hide agent panel").accessibilityLabel("Hide agent panel")
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            .padding(.horizontal, 10).frame(height: 34)
            NeoLinkTheme.horizontalSeparator()
            if !controller.agentPanelTabs.isEmpty || !controller.acpSessions.isEmpty {
                HStack {
                    Picker("Session", selection: Binding(get: { controller.agentSelection }, set: { controller.agentSelection = $0 })) {
                        ForEach(controller.acpSessions) { session in Text(session.agent.name + " · ACP").tag("acp:" + session.id.uuidString) }
                        ForEach(controller.agentPanelTabs) { tab in Text(tab.title).tag("terminal:" + tab.id.uuidString) }
                    }.labelsHidden()
                    Button { controller.refreshAgentEdits() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh saved agent edits").accessibilityLabel("Refresh agent edits")
                    Button {
                        if let id = controller.selectedACPID { controller.closeACP(id) }
                        else if let id = controller.agentPanelTabID { controller.requestCloseTab(id) }
                    } label: { Image(systemName: "xmark") }
                        .help("Close agent session").accessibilityLabel("Close agent session")
                }.buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 32)
                if let session = controller.selectedACP {
                    ACPConversationHost(selection: controller.selection, controller: controller, session: session).id(session.id)
                } else {
                    TerminalViewRepresentable(tabs: controller.agentPanelTabs, selectedTabID: controller.agentPanelTabID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text(controller.selectedACP == nil ? "Project terminal" : "Agent conversation")
                    Spacer()
                    let count = controller.agentPanelTabs.count + controller.acpSessions.count
                    Text("\(count) \(count == 1 ? "session" : "sessions")")
                }.font(.system(size: 10)).foregroundStyle(NeoLinkTheme.textSecondary)
                    .padding(.horizontal, 10).frame(height: 22)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Work alongside your code")
                        .font(.system(size: 13, weight: .medium))
                    Text("Start a native ACP conversation or an agent terminal in your project. Keep the editor open while it works.")
                        .font(.system(size: 12)).foregroundStyle(NeoLinkTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: launch) {
                        HStack { Image(systemName: "plus"); Text("New agent session"); Spacer(); Text("⌃⌘A").foregroundStyle(NeoLinkTheme.textSecondary) }
                            .font(.system(size: 12)).padding(10)
                            .background(NeoLinkTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }.padding(16)
                Spacer()
            }
        }
        .foregroundStyle(NeoLinkTheme.textPrimary)
        .background(NeoLinkTheme.editorBackground)
    }
}

/// The conversation's context is the selected file: only this view follows tab switches, not the whole panel.
private struct ACPConversationHost: View {
    @ObservedObject var selection: TabSelection
    let controller: TabsController
    let session: ACPSession

    private var selectedFileURL: URL? {
        if case .local(let url) = controller.selectedTab?.document?.source { return url }
        return nil
    }

    var body: some View {
        ACPConversationView(session: session, contextURL: selectedFileURL, focusChanged: { focused in
            if focused { controller.focusedACPID = session.id }
            else if controller.focusedACPID == session.id { controller.focusedACPID = nil }
        })
    }
}
