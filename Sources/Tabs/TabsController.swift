import Foundation

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    let configuration: TerminalConfiguration
    let state: TerminalState

    init(id: UUID = UUID(), title: String, configuration: TerminalConfiguration, currentDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.state = TerminalState(currentDirectory: currentDirectory)
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.configuration == rhs.configuration
    }
}

final class TabsController: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selectedTabID: UUID?

    init() {
        let initial = TerminalTab(
            title: "Local",
            configuration: TerminalConfiguration(backend: .localShell),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        tabs = [initial]
        selectedTabID = initial.id
    }

    func openTab(title: String, configuration: TerminalConfiguration) {
        let directory: String?
        if configuration.backend == .localShell {
            directory = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            directory = nil
        }
        let tab = TerminalTab(title: title, configuration: configuration, currentDirectory: directory)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openLocalTab() {
        openTab(title: "Local", configuration: TerminalConfiguration(backend: .localShell))
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].state.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            openLocalTab()
        } else if selectedTabID == tabID {
            // Keep the user's place in the strip instead of jumping to its first tab.
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectNextTab() { selectTab(offset: 1) }
    func selectPreviousTab() { selectTab(offset: -1) }

    private func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    var selectedTab: TerminalTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }
}
