import AppKit

struct FolderBookmarkOperations {
    var resolve: (Data) throws -> (url: URL, stale: Bool)
    var create: (URL) throws -> Data
    var startAccess: (URL) -> Bool
    var stopAccess: (URL) -> Void

    static let system = FolderBookmarkOperations(
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        create: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Keep user-selected folders available across launches without repeatedly opening a picker.
@MainActor
final class WorkspaceAccess: ObservableObject {
    static let shared = WorkspaceAccess()
    @Published private(set) var projectURL: URL?
    @Published private(set) var recentFolders: [URL] = []
    @Published var error: String?
    private var scopedURLs: [URL] = []
    private let defaults: UserDefaults
    private let operations: FolderBookmarkOperations
    private let key = "workspaceFolderBookmarks"
    private struct SavedFolder {
        var data: Data
        var url: URL?
    }
    private var savedFolders: [SavedFolder] = []
    var hasSavedFolders: Bool { !savedFolders.isEmpty }

    init(defaults: UserDefaults = .standard, operations: FolderBookmarkOperations = .system) {
        self.defaults = defaults
        self.operations = operations
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            var folder = SavedFolder(data: data)
            do {
                let resolved = try operations.resolve(data)
                folder.url = resolved.url
                if resolved.stale, let refreshed = try? operations.create(resolved.url) { folder.data = refreshed }
            } catch {
                // A disconnected drive or temporary resolution failure must not erase a grant.
                // Keep its bookmark so the next launch can restore it without another picker.
            }
            savedFolders.append(folder)
        }
        persistFolders()
        if let path = defaults.string(forKey: "activeProjectPath") {
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            if let url = recentFolders.first(where: { $0.path == canonical }) { select(url) }
        }
    }

    private func persistFolders() {
        defaults.set(savedFolders.map(\.data), forKey: key)
        var seen = Set<URL>()
        recentFolders = savedFolders.compactMap(\.url).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    private func startAccess(to url: URL) {
        if !scopedURLs.contains(url), operations.startAccess(url) { scopedURLs.append(url) }
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
        let bookmarkData = try operations.create(url)
        savedFolders.removeAll { $0.url?.standardizedFileURL == url.standardizedFileURL }
        savedFolders.insert(SavedFolder(data: bookmarkData, url: url), at: 0)
        persistFolders()
        select(url)
    }

    func select(_ url: URL) {
        let url = url.standardizedFileURL
        // Only activate folders that are in use, rather than every recent location on launch.
        let scoped = savedFolders.first { $0.url?.standardizedFileURL == url }?.url ?? url
        startAccess(to: scoped)
        projectURL = url
        defaults.set(url.path, forKey: "activeProjectPath")
        error = nil
    }

    /// Forget the shortcut and future restoration, without disrupting open files
    /// or security scopes still being used by terminals/editors this session.
    func forget(_ url: URL) {
        let canonical = url.standardizedFileURL
        savedFolders.removeAll { $0.url?.standardizedFileURL == canonical }
        if let path = defaults.string(forKey: "activeProjectPath"),
           URL(fileURLWithPath: path).standardizedFileURL == canonical {
            defaults.removeObject(forKey: "activeProjectPath")
        }
        persistFolders()
    }

    func clearRecentFolders() {
        savedFolders.removeAll()
        defaults.removeObject(forKey: "activeProjectPath")
        persistFolders()
    }

    deinit { scopedURLs.forEach(operations.stopAccess) }
}
