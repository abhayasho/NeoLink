import AppKit
import Combine
import SwiftUI

@MainActor
final class TextSizePreferences: ObservableObject {
    static let shared = TextSizePreferences()
    static let defaultSize: CGFloat = 13
    static let range: ClosedRange<CGFloat> = 9...32
    @Published private(set) var pointSize: CGFloat
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: "workspaceTextSize") as? Double ?? Double(Self.defaultSize)
        pointSize = Self.clamp(CGFloat(saved))
    }

    private static func clamp(_ size: CGFloat) -> CGFloat {
        size.isFinite ? min(range.upperBound, max(range.lowerBound, size)) : defaultSize
    }

    func set(_ size: CGFloat) {
        let next = Self.clamp(size)
        guard next != pointSize else { return }
        pointSize = next
        defaults.set(Double(next), forKey: "workspaceTextSize")
    }
    func adjust(by delta: CGFloat) { set(pointSize + delta) }
    func reset() { set(Self.defaultSize) }
}

struct TextSizeControl: View {
    @ObservedObject private var preferences = TextSizePreferences.shared
    var body: some View {
        Menu {
            Button("Increase Text Size  ⌘+") { preferences.adjust(by: 1) }
            Button("Decrease Text Size  ⌘−") { preferences.adjust(by: -1) }
            Divider()
            Button("Reset to 13 pt  ⌘0") { preferences.reset() }
            Divider()
            ForEach([10, 12, 13, 14, 16, 18, 20, 24], id: \.self) { size in
                Button("\(size) pt") { preferences.set(CGFloat(size)) }
            }
        } label: { Text("\(Int(preferences.pointSize)) pt").monospacedDigit() }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Text size (⌘+ / ⌘− / ⌘0)").accessibilityLabel("Text size")
    }
}
