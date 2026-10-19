import Foundation

/// Keep a tab's manually browsed directory and filter when its terminal is out of view.
@MainActor
final class WorkspaceFileBrowsers: ObservableObject {
    private var browsers: [UUID: LocalFileBrowserViewModel] = [:]

    func browser(for tab: TerminalTab) -> LocalFileBrowserViewModel {
        if let browser = browsers[tab.id] { return browser }
        let startingURL = tab.state.currentDirectory.flatMap { path -> URL? in
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        let browser = LocalFileBrowserViewModel(startingAt: startingURL)
        browsers[tab.id] = browser
        return browser
    }

    func retainTabs(_ ids: Set<UUID>) {
        browsers = browsers.filter { ids.contains($0.key) }
    }
}
