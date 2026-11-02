import AppKit

/// Keep user-selected folders available across launches without repeatedly opening a picker.
@MainActor
final class WorkspaceAccess: ObservableObject {
    static let shared = WorkspaceAccess()
    @Published private(set) var projectURL: URL?
    @Published private(set) var recentFolders: [URL] = []
    @Published var error: String?
    private var scopedURLs: [URL] = []
    private let defaults: UserDefaults
    private let key = "workspaceFolderBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var refreshed: [Data] = []
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            do {
                var stale = false
                let scoped = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                if scoped.startAccessingSecurityScopedResource() { scopedURLs.append(scoped) }
                let url = scoped.standardizedFileURL.resolvingSymlinksInPath()
                recentFolders.append(url)
                refreshed.append(stale ? try bookmark(scoped) : data)
            } catch { self.error = "A saved folder is no longer available. Choose it again with Open Project." }
        }
        defaults.set(refreshed, forKey: key)
        if let path = defaults.string(forKey: "activeProjectPath") {
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            projectURL = recentFolders.first { $0.path == canonical }
        }
    }

    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func chooseFolder(completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder. NeoLink remembers this access for future launches."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Project"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do {
                try self.remember(url)
                completion?(url)
            } catch { self.error = error.localizedDescription }
        }
    }

    func remember(_ url: URL) throws {
        let bookmarkData = try bookmark(url)
        if !scopedURLs.contains(url), url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        var bookmarks = defaults.array(forKey: key) as? [Data] ?? []
        if let index = recentFolders.firstIndex(of: url) {
            recentFolders.remove(at: index)
            if index < bookmarks.count { bookmarks.remove(at: index) }
        }
        recentFolders.insert(url, at: 0)
        bookmarks.insert(bookmarkData, at: 0)
        defaults.set(bookmarks, forKey: key)
        select(url)
    }

    func select(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        projectURL = url
        defaults.set(url.path, forKey: "activeProjectPath")
        error = nil
    }

    deinit { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
}
