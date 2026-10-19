import SwiftUI

struct TabbedTerminalView: View {
    @ObservedObject var controller: TabsController

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            NeoLinkTheme.horizontalSeparator()

            TerminalViewRepresentable(tabs: controller.tabs, selectedTabID: controller.selectedTabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 8)
                .padding(.top, 8)

            if let tab = controller.selectedTab {
                TerminalStatusBar(tab: tab)
                    .id(tab.id)
            }
        }
        .background(NeoLinkTheme.editorBackground)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.tabs) { tab in
                            TerminalTabButton(
                                tab: tab,
                                isSelected: controller.selectedTabID == tab.id,
                                select: { controller.selectedTabID = tab.id },
                                close: { controller.closeTab(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .onChange(of: controller.selectedTabID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }

            Button(action: controller.openLocalTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NeoLinkTheme.textSecondary)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New local terminal (⌘T)")
            .accessibilityLabel("New local terminal")
            .padding(.horizontal, 5)
        }
        .frame(height: 42)
        .background(NeoLinkTheme.panelBackground)
    }
}

private struct TerminalTabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    private var icon: String {
        switch tab.configuration.backend {
        case .localShell: return "terminal"
        case .ssh: return "network"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(isSelected ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(isSelected ? NeoLinkTheme.textPrimary : NeoLinkTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tab.title) terminal")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(NeoLinkTheme.textSecondary.opacity(isHovered || isSelected ? 1 : 0.55))
                    .frame(width: 27, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal")
            .accessibilityLabel("Close \(tab.title) terminal")
            .padding(.trailing, 3)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(width: 170, height: 36)
        .background(isSelected ? NeoLinkTheme.editorBackground : (isHovered ? NeoLinkTheme.rowHover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? NeoLinkTheme.accent : Color.clear)
                .frame(height: 2)
        }
        .onHover { isHovered = $0 }
        .help(tab.title)
        .contextMenu {
            Button("Close terminal", action: close)
        }
    }
}

private struct TerminalStatusBar: View {
    let tab: TerminalTab
    @ObservedObject private var state: TerminalState

    init(tab: TerminalTab) {
        self.tab = tab
        self.state = tab.state
    }

    private var status: String {
        switch state.processStatus {
        case .idle: return "Starting…"
        case .running:
            if case .localShell = tab.configuration.backend { return "Local shell" }
            return "SSH session"
        case .exited:
            return "Session ended"
        }
    }

    private var directory: String {
        guard let directory = state.currentDirectory, !directory.isEmpty else {
            if case let .ssh(host, username, _) = tab.configuration.backend { return "\(username)@\(host)" }
            return "~"
        }
        if case .localShell = tab.configuration.backend {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if directory == home { return "~" }
            if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        }
        return directory
    }

    var body: some View {
        VStack(spacing: 0) {
            NeoLinkTheme.horizontalSeparator()
            HStack(spacing: 7) {
                Circle()
                    .fill(state.processStatus == .running ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 10)
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(directory)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.currentDirectory ?? directory)
            }
            .foregroundColor(NeoLinkTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
    }
}
