import AppKit
import SwiftUI

/// AppKit owns horizontal momentum and nearest-edge reveal. SwiftUI retains the
/// buttons and their stable identities; no selection scroll animation is queued.
struct TabStripViewport<Content: View>: NSViewRepresentable {
    let selected: UUID?
    let frames: [UUID: CGRect]
    let width: CGFloat
    let content: Content
    func makeNSView(context: Context) -> TabStripScrollView<Content> {
        TabStripScrollView(content: content)
    }
    func updateNSView(_ scroll: TabStripScrollView<Content>, context: Context) {
        scroll.host.rootView = content
        scroll.contentWidth = width
        if scroll.selection != selected {
            scroll.selection = selected
            scroll.reveal = selected.flatMap { frames[$0] }
        }
        scroll.needsLayout = true
    }
}
final class TabStripScrollView<Content: View>: NSScrollView {
    let host: NSHostingView<Content>
    var contentWidth: CGFloat = 0
    var selection: UUID?
    var reveal: CGRect?
    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasHorizontalScroller = true; hasVerticalScroller = false
        scrollerStyle = .overlay; autohidesScrollers = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        documentView = host
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let size = CGSize(width: max(contentWidth, contentView.bounds.width), height: 34)
        if host.frame.size != size { host.setFrameSize(size) }
        if let item = reveal, contentView.bounds.width > 0 {
            reveal = nil
            let origin = TabPresentation.revealOrigin(item: item, viewport: contentView.bounds, contentWidth: size.width)
            if abs(origin - contentView.bounds.minX) > 0.01 {
                contentView.scroll(to: CGPoint(x: origin, y: 0)); reflectScrolledClipView(contentView)
            }
        }
    }
}
