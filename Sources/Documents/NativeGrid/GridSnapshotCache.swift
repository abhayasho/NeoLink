import Foundation
import Darwin
import SwiftTerm

typealias ExternalGridStyleValue = ExternalGridStyle

/// A cheap on-disk identity used to prove a cached image still shows the file's contents.
struct FileSignature: Equatable, Sendable {
    var size: UInt64
    var seconds: Int
    var nanoseconds: Int
    var inode: UInt64
    static func current(path: String) -> FileSignature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileSignature(size: UInt64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, inode: UInt64(info.st_ino))
    }
}

/// The last acknowledged screen of each inactive buffer, kept only while it is provably still
/// what Neovim would draw: nothing touched the buffer, the window and style are unchanged, and
/// the file on disk is the one on screen. Every other case waits for Neovim's own flush.
struct GridSnapshotCache {
    struct Entry {
        var image: GridImage
        var styleEpoch: Int
        var diagnosticsEnabled: Bool
        var signature: FileSignature?
        var stamp: UInt64 = 0
    }

    static let limit = 16
    private(set) var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    mutating func store(_ entry: Entry, for path: String) {
        var entry = entry
        clock &+= 1; entry.stamp = clock
        entries[path] = entry
        if entries.count > Self.limit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key { entries.removeValue(forKey: oldest) }
    }
    mutating func remove(_ path: String) { entries.removeValue(forKey: path) }
    mutating func removeAll() { entries.removeAll() }
    /// An empty path means a change that affects every image (layout, option or colour scheme).
    mutating func invalidate(path: String) { if path.isEmpty { entries.removeAll() } else { entries.removeValue(forKey: path) } }

    /// The entry for `path` when every condition for showing it holds.
    func validEntry(for path: String, cols: Int, rows: Int, styleEpoch: Int, diagnosticsEnabled: Bool,
                    signature: FileSignature?) -> Entry? {
        guard let entry = entries[path], entry.image.cols == cols, entry.image.rowCount == rows, entry.styleEpoch == styleEpoch,
              entry.diagnosticsEnabled == diagnosticsEnabled, entry.signature == signature else { return nil }
        return entry
    }
}

/// Resolves Neovim highlight ids into terminal cell styles, with a per-id cache.
final class GridStyleTable {
    private(set) var highlights: [Int32: GridHighlight] = [:]
    private(set) var defaults = GridDefaults()
    private(set) var epoch = 0
    /// Increments when the default colours change, so the host can retint its background.
    private(set) var defaultsRevision = 0
    private var cache: [Int32: ExternalGridStyleValue] = [:]

    func absorb(_ frame: GridFrame) {
        epoch = frame.styleEpoch
        if let next = frame.defaults, next != defaults { defaults = next; defaultsRevision += 1; cache.removeAll() }
        for (id, highlight) in frame.highlights {
            highlights[id] = highlight
            cache.removeValue(forKey: id)
        }
    }

    func style(for id: Int32) -> ExternalGridStyleValue {
        if let cached = cache[id] { return cached }
        let highlight = highlights[id] ?? GridHighlight()
        var foreground = highlight.foreground ?? defaults.foreground
        var background = highlight.background ?? defaults.background
        if highlight.reverse { swap(&foreground, &background) }
        let underline: ExternalGridStyleValue.Underline
        switch highlight.underline {
        case 1: underline = .single
        case 2: underline = .curly
        case 3: underline = .double
        case 4: underline = .dotted
        case 5: underline = .dashed
        default: underline = .none
        }
        let style = ExternalGridStyleValue(foreground: foreground == defaults.foreground ? nil : foreground,
                                           background: background == defaults.background ? nil : background,
                                           special: highlight.special ?? defaults.special, bold: highlight.bold, italic: highlight.italic,
                                           strikethrough: highlight.strikethrough, underline: underline)
        cache[id] = style
        return style
    }
}
