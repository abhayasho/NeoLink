import SwiftUI

struct TabbedTerminalView: View {
    @ObservedObject var controller: TabsController
    /// The selection is published separately from the controller (see `TabSelection`).
    @ObservedObject private var selection: TabSelection

    init(controller: TabsController) {
        _controller = ObservedObject(wrappedValue: controller)
        _selection = ObservedObject(wrappedValue: controller.selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            NeoLinkTheme.horizontalSeparator()

            ZStack {
                VStack(spacing: 0) {
                    TerminalViewRepresentable(tabs: controller.workspaceTerminalTabs, selectedTabID: controller.selectedTerminalTab?.id,
                                              isActive: controller.selectedTab?.document == nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 8)
                        .padding(.top, 8)
                    if let tab = controller.selectedTerminalTab {
                        TerminalStatusBar(tab: tab).id(tab.id)
                    }
                }
                .opacity(controller.selectedTab?.document == nil ? 1 : 0)
                .allowsHitTesting(controller.selectedTab?.document == nil)
                .accessibilityHidden(controller.selectedTab?.document != nil)

                EditorPane(controller: controller, selection: selection, session: controller.codeSession)
                if let document = controller.selectedTab?.document, !document.usesNeovim {
                    DocumentTabView(document: document).id(document.id)
                }
            }
        }
        .background(NeoLinkTheme.editorBackground)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            let tabs = controller.workspaceTabs
            let presentations = TabPresentation.make(titles: tabs.map(\.title), paths: tabs.map { $0.document?.source.displayPath })
            let widths = presentations.map(\.width)
            let offsets = widths.reduce(into: [CGFloat(0)]) { $0.append($0.last! + $1) }
            let frames = Dictionary(uniqueKeysWithValues: tabs.indices.map { (tabs[$0].id, CGRect(x: offsets[$0], y: 0, width: widths[$0], height: 34)) })
            TabStripViewport(selected: selection.id, frames: frames, width: offsets.last ?? 0,
                content: HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        Group {
                            if let document = tab.document {
                                DocumentTabButton(document: document, controller: controller, presentation: presentations[index],
                                                  isSelected: selection.id == document.id)
                            } else {
                                WorkspaceTabButton(
                                    title: tab.title, presentation: presentations[index],
                                    icon: tab.terminal?.agentName != nil ? "sparkles" : (tab.terminal?.configuration.backend == .localShell ? "terminal" : "network"),
                                    detail: "\(tab.title) terminal",
                                    isSelected: selection.id == tab.id,
                                    isModified: false,
                                    select: { controller.selectedTabID = tab.id },
                                    close: { controller.requestCloseTab(tab.id) }
                                )
                            }
                        }.id(tab.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 34))

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
        .frame(height: 34)
        .background(NeoLinkTheme.panelBackground)
    }
}

/// Session mode/readiness changes stay inside the editor instead of invalidating
/// the terminal host and every tab-strip button.
private struct EditorPane: View {
    @ObservedObject var controller: TabsController
    @ObservedObject var selection: TabSelection
    @ObservedObject var session: NeovimSession
    var body: some View {
        if session.isStarted || controller.selectedTab?.document?.usesNeovim == true {
            CodeWorkspaceView(session: session, controller: controller, selection: selection)
                .opacity(controller.selectedTab?.document?.usesNeovim == true ? 1 : 0)
                .allowsHitTesting(controller.selectedTab?.document?.usesNeovim == true)
                .accessibilityHidden(controller.selectedTab?.document?.usesNeovim != true)
        }
    }
}

private struct DocumentTabButton: View {
    @ObservedObject var document: WorkspaceDocument
    /// For actions only: the button depends on the controller through `isSelected`, not on all of its state.
    let controller: TabsController
    let presentation: TabPresentation
    let isSelected: Bool

    var body: some View {
        WorkspaceTabButton(title: document.title, presentation: presentation, icon: document.icon, detail: document.source.displayPath,
                           isSelected: isSelected, isModified: document.isModified,
                           select: { controller.selectedTabID = document.id }, close: { controller.requestCloseTab(document.id) })
    }
}

private struct WorkspaceTabButton: View {
    let title: String
    let presentation: TabPresentation
    let icon: String
    let detail: String
    let isSelected: Bool
    let isModified: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(isSelected ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
                        .frame(width: 14)
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .regular))
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(isSelected ? NeoLinkTheme.textPrimary : NeoLinkTheme.textSecondary)
                    if !presentation.context.isEmpty {
                        Text(presentation.context).font(.system(size: 11)).foregroundColor(NeoLinkTheme.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 100)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(isModified ? NeoLinkTheme.accent : Color.clear).frame(width: 6, height: 6)
                        .accessibilityHidden(!isModified).accessibilityLabel("Unsaved changes")
                }
                .padding(.leading, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detail)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(NeoLinkTheme.textSecondary.opacity(isHovered || isSelected ? 1 : 0.55))
                    .frame(width: 27, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close \(detail) tab")
            .padding(.trailing, 3)
        }
        .font(.system(size: 12))
        .frame(width: presentation.width, height: 34)
        .background(isSelected ? NeoLinkTheme.editorBackground : (isHovered ? NeoLinkTheme.rowHover : Color.clear))
        .overlay(alignment: .trailing) { NeoLinkTheme.verticalSeparator() }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? NeoLinkTheme.accent : Color.clear)
                .frame(height: 1)
        }
        .onHover { isHovered = $0 }
        .help(detail)
        .contextMenu {
            Button("Close tab", action: close)
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
            if let name = tab.agentName { return "\(name) terminal" }
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
