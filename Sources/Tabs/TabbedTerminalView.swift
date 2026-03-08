import SwiftUI

struct TabbedTerminalView: View {
    @ObservedObject var controller: TabsController
    @ObservedObject var terminalState: TerminalState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(controller.tabs) { tab in
                    Button(action: { controller.selectedTabID = tab.id }) {
                        Text(tab.title)
                            .foregroundColor(controller.selectedTabID == tab.id ? NeoLinkTheme.textPrimary : NeoLinkTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(controller.selectedTabID == tab.id ? NeoLinkTheme.selectionBlue.opacity(0.6) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close") {
                            controller.closeTab(tab.id)
                        }
                    }
                }

                Spacer()

                Button(action: controller.openLocalTab) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .background(NeoLinkTheme.panelBackground)

            NeoLinkTheme.horizontalSeparator()

            HStack {
                Text(terminalState.currentDirectory ?? "")
                    .font(.caption2)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            if let tab = controller.selectedTab {
                TerminalViewRepresentable(configuration: tab.configuration, state: terminalState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No tab selected")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

