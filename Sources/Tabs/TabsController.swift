import Foundation

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var configuration: TerminalConfiguration
}

final class TabsController: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selectedTabID: UUID?

    init() {
        let initial = TerminalTab(
            id: UUID(),
            title: "Local",
            configuration: TerminalConfiguration(backend: .localShell)
        )
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    func openTab(title: String, configuration: TerminalConfiguration) {
        let tab = TerminalTab(id: UUID(), title: title, configuration: configuration)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openLocalTab() {
        openTab(title: "Local", configuration: TerminalConfiguration(backend: .localShell))
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabs.first?.id
        }
        if tabs.isEmpty {
            openLocalTab()
        }
    }

    var selectedTab: TerminalTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }
}

