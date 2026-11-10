import SwiftUI

struct SemanticFileIcon: View {
    let url: URL
    var directory = false
    var expanded = false
    var body: some View {
        let _ = LayoutTrace.body("SemanticFileIcon")
        let look = Self.appearance(url: url, directory: directory, expanded: expanded)
        Group {
            if let text = look.abbreviation { Text(text).font(.system(size: 8, weight: .bold, design: .monospaced)) }
            else { Image(systemName: look.symbol).font(.system(size: 12)) }
        }
        .foregroundStyle(look.color).frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }

    /// The icon's resolved look, shared by this SwiftUI view and the AppKit explorer cell so both
    /// draw identically. `abbreviation` (e.g. "Sw") takes precedence over `symbol` when present.
    struct Look { let symbol: String; let abbreviation: String?; let color: Color }
    static func appearance(url: URL, directory: Bool, expanded: Bool) -> Look {
        if directory {
            return Look(symbol: expanded ? "folder.fill" : "folder", abbreviation: nil, color: NeoLinkTheme.textSecondary)
        }
        return Look(symbol: symbol(for: url), abbreviation: abbreviation(for: url), color: color(for: url))
    }

    private var abbreviation: String? { Self.abbreviation(for: url) }
    private var symbol: String { Self.symbol(for: url) }
    private var color: Color { Self.color(for: url) }

    private static func abbreviation(for url: URL) -> String? {
        if ["Dockerfile", "Containerfile"].contains(url.lastPathComponent) { return "◈" }
        return ["swift":"Sw", "py":"Py", "pyi":"Py", "js":"JS", "jsx":"JS", "ts":"TS", "tsx":"TS", "rs":"Rs", "go":"Go", "java":"J", "kt":"Kt", "rb":"Rb", "c":"C", "h":"H", "cpp":"C+", "hpp":"H+", "cs":"C#", "lua":"Lu", "sh":"$", "bash":"$", "zsh":"$", "html":"<>", "css":"#", "scss":"#", "json":"{}", "jsonc":"{}", "yaml":"Y", "yml":"Y", "toml":"T"] [url.pathExtension.lowercased()]
    }
    private static func symbol(for url: URL) -> String {
        if url.lastPathComponent == ".editorconfig" || url.lastPathComponent.hasPrefix(".git") || url.lastPathComponent.hasPrefix(".env") { return "gearshape" }
        switch url.pathExtension.lowercased() {
        case "md", "mdx": return "text.alignleft"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "heic": return "photo"
        case "zip", "gz", "tar": return "doc.zipper"
        default: return "doc.text"
        }
    }
    private static func color(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift", "rs", "html": return NeoLinkTheme.syntaxOrange
        case "js", "jsx", "sh", "bash", "zsh": return NeoLinkTheme.syntaxYellow
        case "py", "pyi", "ts", "tsx", "go", "md", "pdf": return NeoLinkTheme.syntaxBlue
        case "json", "jsonc", "css", "scss", "yaml", "yml": return NeoLinkTheme.syntaxPink
        default: return NeoLinkTheme.textSecondary
        }
    }
}

extension ExplorerGitSnapshot.State {
    var color: Color {
        switch self {
        case .added, .untracked: return NeoLinkTheme.success
        case .modified: return NeoLinkTheme.syntaxBlue
        case .deleted, .conflict: return NeoLinkTheme.error
        case .renamed: return NeoLinkTheme.syntaxOrange
        case .ignored: return NeoLinkTheme.textSecondary
        }
    }
    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .conflict: return "Merge conflict"
        case .ignored: return "Ignored by Git"
        }
    }
}
