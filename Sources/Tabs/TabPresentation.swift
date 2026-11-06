import AppKit

/// Geometry depends on names/paths, never selection, hover or modified state.
struct TabPresentation: Equatable {
    let title: String
    let context: String
    let width: CGFloat
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 320
    static let chromeWidth: CGFloat = 96 // icon, gaps, reserved dirty indicator, close

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let lock = NSLock()
    private static var measured: [String: CGFloat] = [:]
    private static var lastInput: (titles: [String], paths: [String?])?
    private static var lastOutput: [TabPresentation] = []

    /// Text measurement dominates tab-strip body evaluation. The result is a pure
    /// function of the string and the fixed 12 pt system font, so reuse it; the
    /// cache is bounded and never holds UI state.
    static func measure(_ text: String) -> CGFloat {
        lock.lock()
        if let cached = measured[text] { lock.unlock(); return cached }
        lock.unlock()
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        lock.lock()
        if measured.count >= 4096 { measured.removeAll(keepingCapacity: true) }
        measured[text] = width
        lock.unlock()
        return width
    }
    /// Selection changes re-evaluate the strip with unchanged names/paths; reuse
    /// the previous immutable result instead of recomputing disambiguation.
    static func make(titles: [String], paths: [String?]) -> [TabPresentation] {
        precondition(titles.count == paths.count)
        lock.lock()
        if let last = lastInput, last.titles == titles, last.paths == paths { let out = lastOutput; lock.unlock(); return out }
        lock.unlock()
        let result = compute(titles: titles, paths: paths)
        lock.lock(); lastInput = (titles, paths); lastOutput = result; lock.unlock()
        return result
    }
    private static func compute(titles: [String], paths: [String?]) -> [TabPresentation] {
        let contexts: [String] = titles.indices.map { index in
            let title = titles[index]
            let peers = titles.indices.filter { $0 != index && titles[$0] == title }
            var context = ""
            if !peers.isEmpty, let path = paths[index] {
                let components = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
                for depth in 1...max(1, components.count) {
                    let candidate = components.suffix(depth).joined(separator: "/")
                    context = candidate
                    if peers.allSatisfy({ other in
                        guard let otherPath = paths[other] else { return true }
                        return (otherPath as NSString).deletingLastPathComponent.split(separator: "/").suffix(depth).joined(separator: "/") != candidate
                    }) { break }
                }
            }
            return context
        }
        return titles.indices.map { index in
            let title = titles[index]
            let context = compact(contexts[index], among: contexts, width: 100)
            let available = maximumWidth - chromeWidth - (context.isEmpty ? 0 : min(100, measure(context)) + 8)
            let fitted = compact(title, among: titles, width: max(100, available))
            let width = min(maximumWidth, max(minimumWidth, measure(fitted) + chromeWidth + (context.isEmpty ? 0 : min(100, measure(context)) + 8)))
            return .init(title: fitted, context: context, width: width)
        }
    }
    /// Keep both ends normally; if that would hide the only distinguishing part,
    /// retain a window around the first different character instead.
    static func compact(_ title: String, among peers: [String], width: CGFloat) -> String {
        guard measure(title) > width else { return title }
        let characters = Array(title)
        func middle(_ chars: [Character]) -> String {
            var count = chars.count
            while count > 4 {
                let head = (count + 1) / 2, tail = count / 2
                let candidate = String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
                if measure(candidate) <= width { return candidate }
                count -= 1
            }
            return String(chars.prefix(2)) + "…" + String(chars.suffix(2))
        }
        let conventional = middle(characters)
        let collisions = peers.filter { $0 != title && middle(Array($0)) == conventional }
        guard !collisions.isEmpty else { return conventional }
        let prefix = collisions.map { other in zip(characters, Array(other)).prefix { $0 == $1 }.count }.min() ?? 0
        var start = max(0, prefix - 3), end = min(characters.count, prefix + 12)
        func candidate() -> String {
            (start == 0 ? "" : "…") + String(characters[start..<end]) + (end == characters.count ? "" : "…") + (title as NSString).pathExtension.withDot
        }
        while measure(candidate()) > width, end - start > 4 {
            if start < prefix { start += 1 } else { end -= 1 }
        }
        return candidate()
    }
    static func revealOrigin(item: CGRect, viewport: CGRect, contentWidth: CGFloat) -> CGFloat {
        let proposed: CGFloat
        if item.width > viewport.width { proposed = item.minX }
        else if item.minX < viewport.minX { proposed = item.minX }
        else if item.maxX > viewport.maxX { proposed = item.maxX - viewport.width }
        else { proposed = viewport.minX }
        return max(0, min(max(0, contentWidth - viewport.width), proposed))
    }
}
private extension String { var withDot: String { isEmpty ? "" : "." + self } }
