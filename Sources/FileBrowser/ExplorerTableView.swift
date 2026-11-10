import AppKit
import SwiftUI

/// The project tree drawn with a native `NSTableView` (view-based, row views recycled) instead
/// of a SwiftUI `List`/`LazyVStack`. The table is driven by the existing flattened
/// `ExplorerTree.rows`; this view owns no tree logic. Rows are plain AppKit views (no per-row
/// SwiftUI hosting). Hover and selection repaint only the affected rows, and `tree.rows`
/// changes are applied as incremental insert/remove/configure so hover, selection, diagnostics or
/// unrelated terminal activity never reload the whole table or disturb the scroll position.
///
/// This is a testable change, not a guaranteed cure for scroll jank: a native table can still
/// hitch, and the benchmark has not isolated the cause. Judge it on the trackpad.
struct ExplorerTableView: NSViewRepresentable {
    @ObservedObject private var rendering = TerminalRenderingPreferences.shared
    @ObservedObject var tree: ExplorerTree
    let activeFileURL: URL?
    /// Row actions, kept in the SwiftUI layer so behavior matches the old row exactly.
    let onToggle: (ExplorerRow) -> Void
    let onOpen: (LocalFileItem) -> Void
    let contextMenu: (ExplorerRow) -> NSMenu
    let canAcceptDrop: (ExplorerRow?, [URL]) -> Bool
    let onDrop: (ExplorerRow?, [URL]) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ExplorerNSTableView()
        table.coordinator = context.coordinator
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none    // Selection is drawn by the row view.
        table.intercellSpacing = .zero
        table.rowHeight = Coordinator.rowHeight
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.focusRingType = .none
        table.setAccessibilityLabel("Project files")
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.rowClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.setDraggingSourceOperationMask([.copy], forLocal: true)
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = ExplorerScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // Responsive (concurrent) scrolling is on by default for view-based tables; keep it.
        context.coordinator.table = table
        context.coordinator.observeScrolling(in: scroll)
        context.coordinator.apply(rows: tree.rows, revision: tree.rowsRevision, activeFileURL: activeFileURL)
        context.coordinator.installMetalSurface()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        LayoutTrace.body("ExplorerTableView.update")
        context.coordinator.parent = self
        context.coordinator.updateRendering(enabled: rendering.useGPU)
        context.coordinator.apply(rows: tree.rows, revision: tree.rowsRevision, activeFileURL: activeFileURL)
        context.coordinator.revealIfNeeded(revision: tree.revealRevision, file: tree.selectedURL)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingScrolling()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowHeight: CGFloat = 24
        var parent: ExplorerTableView
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        /// The rows currently in the table, diffed against new snapshots for incremental updates.
        private(set) var rows: [ExplorerRow] = []
        private var activeFileURL: URL?
        private var hoveredRow: Int?
        private var lastReveal = 0
        private var lastRevision: Int?
        private var selectedID: URL?
        private var pendingActiveSelection = false
        private var applying = false
        private struct Snapshot {
            let rows: [ExplorerRow]
            let revision: Int
            let activeFileURL: URL?
        }
        private var deferredSnapshot: Snapshot?
        private var displayedRoot: URL?
        private var trackingScroll = false
        private(set) var deferringUpdates = false
        private var scrollQuietWork: DispatchWorkItem?
        private(set) weak var metalSurface: ExplorerMetalView?
        private var surfaceGeneration = UUID()
        private var preparingSurface = false

        init(_ parent: ExplorerTableView) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self); scrollQuietWork?.cancel() }

        func observeScrolling(in scroll: NSScrollView) {
            stopObservingScrolling()
            self.scroll = scroll
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(scrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrollChanged), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }

        func stopObservingScrolling() {
            updateRendering(enabled: false)
            // NSTableView also registers its delegate for selection notifications. Remove
            // only our scroll observations, leaving native selection delivery intact.
            if let scroll {
                for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
                             NSScrollView.didEndLiveScrollNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: scroll)
                }
            }
            scrollQuietWork?.cancel(); scrollQuietWork = nil
            trackingScroll = false; deferringUpdates = false; deferredSnapshot = nil
        }

        func updateRendering(enabled: Bool) {
            if enabled { installMetalSurface() }
            else if metalSurface != nil || preparingSurface {
                surfaceGeneration = UUID(); preparingSurface = false
                metalSurface?.shutdown(); metalSurface?.removeFromSuperview(); metalSurface = nil
            }
        }

        func installMetalSurface() {
            guard TerminalRenderingPreferences.shared.useGPU, metalSurface == nil, !preparingSurface else { return }
            preparingSurface = true
            let token = UUID(); surfaceGeneration = token
            DispatchQueue.global(qos: .userInitiated).async {
                ExplorerMetalView.prepare()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.surfaceGeneration == token else { return }
                    self.preparingSurface = false
                    guard let scroll = self.scroll, self.metalSurface == nil, let surface = ExplorerMetalView(scroll: scroll) else { return }
                    self.metalSurface = surface
                    surface.scene = { [weak self] in
                        guard let self else { return .init(rows: [], active: nil, selected: -1, hovered: nil) }
                        return .init(rows: self.rows, active: self.activeFileURL, selected: self.table?.selectedRow ?? -1, hovered: self.hoveredRow)
                    }
                    surface.coverageChanged = { [weak self] _ in self?.refreshNativeCoverage() }
                    // Keep the GPU viewport fixed while AppKit scrolls the native input table.
                    scroll.addSubview(surface, positioned: .above, relativeTo: scroll.contentView)
                    surface.invalidateScene()
                }
            }
        }

        private func refreshNativeCoverage() {
            (scroll as? ExplorerScrollView)?.usesMetalScrolling = metalSurface?.isCoveringNativeRows == true
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.location < min(rows.count, NSMaxRange(visible)) else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for row in visible.location..<min(rows.count, NSMaxRange(visible)) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ExplorerCellView)?.setMetalCovered(metalSurface?.isCoveringNativeRows == true)
            }
            CATransaction.commit()
        }

        @objc func scrollBegan() {
            scrollQuietWork?.cancel(); scrollQuietWork = nil
            trackingScroll = true; deferringUpdates = true
            cancelPendingReveal()
            setHovered(nil)
        }

        @objc private func scrollChanged() {
            deferringUpdates = true
            // Legacy wheels have no begin/end pair. Also bridge the short gap between
            // fingers lifting and AppKit's momentum events without applying a snapshot.
            if !trackingScroll { scheduleQuietFlush() }
        }

        @objc private func scrollEnded() {
            trackingScroll = false
            scheduleQuietFlush()
        }

        private func scheduleQuietFlush() {
            scrollQuietWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finishScrolling() }
            scrollQuietWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        /// Explicit clicks/keys/reveal take precedence over deferred background work.
        /// Otherwise apply only the newest snapshot, after the gesture and momentum stop.
        func finishScrolling() {
            scrollQuietWork?.cancel(); scrollQuietWork = nil
            trackingScroll = false; deferringUpdates = false
            guard let snapshot = deferredSnapshot else { return }
            deferredSnapshot = nil
            apply(rows: snapshot.rows, revision: snapshot.revision, activeFileURL: snapshot.activeFileURL)
        }

        // MARK: Incremental model updates

        /// Replaces the table's rows with `newRows`, touching only what changed. Row identity is
        /// `ExplorerRow.id`; a row whose id stays but whose contents changed is configured in place,
        /// so selection, hover and scroll position survive. A full reload happens only when the
        /// list is first populated or changed too much to diff cheaply.
        func apply(rows newRows: [ExplorerRow], revision: Int, activeFileURL: URL?) {
            let root = parent.tree.root
            let urgent = activeFileURL != self.activeFileURL || root != displayedRoot
            if deferringUpdates, !urgent {
                if revision != lastRevision {
                    deferredSnapshot = Snapshot(rows: newRows, revision: revision, activeFileURL: activeFileURL)
                }
                return
            }
            if urgent {
                scrollQuietWork?.cancel(); scrollQuietWork = nil
                trackingScroll = false; deferringUpdates = false
            }
            deferredSnapshot = nil
            displayedRoot = root
            let activeChanged = activeFileURL != self.activeFileURL
            self.activeFileURL = activeFileURL
            if activeChanged {
                pendingActiveSelection = activeFileURL != nil
                if activeFileURL == nil { cancelPendingReveal() }
            }
            guard let table else { return }
            guard lastRevision != revision else {
                if activeChanged {
                    applying = true
                    selectActiveFile()
                    applying = false
                    refreshVisibleCells(contentChanged: false)
                }
                return
            }
            lastRevision = revision
            let oldRows = rows, oldIDs = rows.map(\.id), newIDs = newRows.map(\.id)
            let newIndices = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
            let oldSelected = selectedID
            let top = min(max(0, Int((scroll?.contentView.bounds.minY ?? 0) / Self.rowHeight)), max(0, rows.count - 1))
            let anchor = rows.indices.contains(top) ? rows[top].id : nil
            let offset = (scroll?.contentView.bounds.minY ?? 0) - CGFloat(top) * Self.rowHeight
            metalSurface?.invalidateRowContent()
            rows = newRows
            applying = true
            defer { applying = false }
            if oldIDs != newIDs {
                let oldSet = Set(oldIDs), newSet = Set(newIDs)
                let stableOrder = oldIDs.filter { newSet.contains($0) } == newIDs.filter { oldSet.contains($0) }
                let removals = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
                let insertions = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
                // Linear membership diff for sorted trees. Bound table mutations for large
                // root/filter replacements instead of computing an unbounded LCS on the UI thread.
                if oldRows.isEmpty || !stableOrder || removals.count + insertions.count > 256 {
                    table.reloadData()
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0; context.allowsImplicitAnimation = false
                        table.beginUpdates()
                        if !removals.isEmpty { table.removeRows(at: removals, withAnimation: []) }
                        if !insertions.isEmpty { table.insertRows(at: insertions, withAnimation: []) }
                        table.endUpdates()
                    }
                }
            }
            var selected = oldSelected.flatMap { id in rows.firstIndex { $0.id == id } }
            if selected == nil, let oldSelected, let index = oldRows.firstIndex(where: { $0.id == oldSelected }) {
                let ancestor = oldRows[..<index].reversed().first { candidate in
                    candidate.depth < oldRows[index].depth && newIndices[candidate.id] != nil
                }
                selected = ancestor.flatMap { ancestor in rows.firstIndex { $0.id == ancestor.id } }
            }
            if activeChanged || oldSelected == nil || pendingActiveSelection {
                if let active = rows.firstIndex(where: { $0.item.id == activeFileURL }) {
                    selected = active
                    pendingActiveSelection = false
                }
            }
            table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
            selectedID = selected.map { rows[$0].id }
            // Recompute hover after membership changes; an old row index can now name another file.
            if oldIDs != newIDs { hoveredRow = nil }
            refreshVisibleCells(contentChanged: false)
            if oldIDs != newIDs, let anchor, let scroll {
                var index = newIDs.firstIndex(of: anchor)
                if index == nil {
                    let ancestor = oldRows.prefix(top).reversed().first {
                        $0.depth < oldRows[top].depth && newIndices[$0.id] != nil
                    }?.id
                    let survivor = ancestor ?? oldIDs.dropFirst(top).first { newIndices[$0] != nil }
                        ?? oldIDs.prefix(top).reversed().first { newIndices[$0] != nil }
                    index = survivor.flatMap { newIndices[$0] }
                }
                if let index {
                    let clip = scroll.contentView
                    let target = min(max(0, table.bounds.height - clip.bounds.height), max(0, CGFloat(index) * Self.rowHeight + offset))
                    if abs(clip.bounds.minY - target) > 0.25 {
                        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target)); scroll.reflectScrolledClipView(clip)
                    }
                }
            }
        }

        private func selectActiveFile() {
            guard let table, let row = rows.firstIndex(where: { $0.item.id == activeFileURL }) else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedID = rows[row].id
            pendingActiveSelection = false
        }

        private func refreshVisibleCells(contentChanged: Bool = true) {
            // Empty trees and viewports beyond a shrinking document have no
            // native cells, but must still retire the previous GPU scene.
            defer {
                if contentChanged { metalSurface?.invalidateScene() }
                else { metalSurface?.invalidateHighlights() }
            }
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.location < min(rows.count, NSMaxRange(visible)) else { return }
            for row in visible.location..<min(rows.count, NSMaxRange(visible)) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ExplorerCellView {
                    cell.configure(rows[row], active: rows[row].item.id == activeFileURL,
                                   selected: row == table.selectedRow, hovered: row == hoveredRow)
                }
            }
            refreshNativeCoverage()
        }

        func cancelPendingReveal() { lastReveal = parent.tree.revealRevision }

        func revealIfNeeded(revision: Int, file: URL?) {
            guard revision != lastReveal, let file else { return }
            if let activeFileURL, file != activeFileURL { return }
            // A gesture begun after this request owns the viewport, including while
            // ancestors are still loading. A later explicit reveal gets a new revision.
            guard !deferringUpdates else { lastReveal = revision; return }
            guard let table, let scroll, let row = rows.firstIndex(where: { $0.item.id == file }) else { return }
            lastReveal = revision
            let clip = scroll.contentView
            let top = CGFloat(row) * Self.rowHeight, bottom = top + Self.rowHeight
            let current = clip.bounds
            let target = top < current.minY ? top : (bottom > current.maxY ? bottom - current.height : current.minY)
            let bounded = min(max(0, table.bounds.height - current.height), max(0, target))
            if bounded != current.minY {
                clip.scroll(to: NSPoint(x: current.minX, y: bounded))
                scroll.reflectScrolledClipView(clip)
            }
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("row")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? ExplorerRowView ?? {
                let v = ExplorerRowView(); v.identifier = id; return v
            }()
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? ExplorerCellView ?? {
                let c = ExplorerCellView(); c.identifier = id; return c
            }()
            let entry = rows[row]
            cell.setMetalCovered(metalSurface?.isCoveringNativeRows == true)
            cell.configure(entry, active: entry.item.id == activeFileURL, selected: row == tableView.selectedRow, hovered: row == hoveredRow)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].name : nil
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            refreshVisibleCells(contentChanged: false)
        }

        // MARK: Clicks and keyboard

        @objc func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            activate(row)
        }

        func activate(_ row: Int) {
            guard rows.indices.contains(row) else { return }
            let entry = rows[row]
            cancelPendingReveal()
            if entry.item.isDirectory { parent.onToggle(entry) }
            else if !entry.missing { parent.onOpen(entry.item) }
        }

        // MARK: Hover (local to the two affected rows)

        func setHovered(_ row: Int?) {
            guard row != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = row
            for index in [previous, row].compactMap({ $0 }) where index >= 0 && index < rows.count {
                if let cell = table?.view(atColumn: 0, row: index, makeIfNecessary: false) as? ExplorerCellView {
                    cell.setHovered(index == row)   // repaint one row, no reload
                }
            }
            metalSurface?.invalidateHighlights()
        }

        // MARK: Context menu

        func menu(for row: Int) -> NSMenu? { rows.indices.contains(row) ? parent.contextMenu(rows[row]) : nil }

        func navigate(right: Bool) {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            let row = table.selectedRow, entry = rows[row]
            var next: Int?
            if right {
                if entry.item.isDirectory && !entry.expanded { parent.onToggle(entry) }
                else if entry.item.isDirectory, row + 1 < rows.count, rows[row + 1].depth > entry.depth { next = row + 1 }
            } else if entry.item.isDirectory && entry.expanded { parent.onToggle(entry) }
            else { next = rows[..<row].lastIndex { $0.depth < entry.depth } }
            if let next { table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next) }
        }

        // MARK: Drag source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < rows.count, !rows[row].missing else { return nil }
            return rows[row].item.url as NSURL
        }

        // MARK: Drop

        func dropTarget(row: Int, operation: NSTableView.DropOperation) -> ExplorerRow? {
            guard operation == .on, rows.indices.contains(row), rows[row].item.isDirectory else { return nil }
            return rows[row]
        }
        func canDrop(row: Int, operation: NSTableView.DropOperation, urls: [URL]) -> Bool {
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            let target = dropTarget(row: row, operation: operation)
            guard target?.missing != true else { return false }
            return parent.canAcceptDrop(target, urls)
        }
        func performDrop(row: Int, operation: NSTableView.DropOperation, urls: [URL]) -> Bool {
            guard canDrop(row: row, operation: operation, urls: urls) else { return false }
            return parent.onDrop(dropTarget(row: row, operation: operation), urls)
        }
        private func urls(from info: NSDraggingInfo) -> [URL] {
            (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard canDrop(row: row, operation: operation, urls: urls(from: info)) else { return [] }
            if dropTarget(row: row, operation: operation) == nil { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            performDrop(row: row, operation: operation, urls: urls(from: info))
        }
    }
}

/// NSTableView that tracks the mouse so the coordinator can set per-row hover without a reload,
/// and routes key presses (arrows, return, right/left to expand/collapse) to the coordinator.
final class ExplorerNSTableView: NSTableView {
    weak var coordinator: ExplorerTableView.Coordinator?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        coordinator?.setHovered(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) { coordinator?.setHovered(nil) }

    override func scrollWheel(with event: NSEvent) {
        coordinator?.setHovered(nil)
        super.scrollWheel(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        coordinator?.cancelPendingReveal()
        coordinator?.finishScrolling()
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.finishScrolling()
        return coordinator?.menu(for: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.cancelPendingReveal()
        coordinator?.finishScrolling()
        guard let coordinator, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76: // Return / Enter
            if selectedRow >= 0 { coordinator.activate(selectedRow) }
        case 123: coordinator.navigate(right: false)
        case 124: coordinator.navigate(right: true)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Row background: selection and hover, drawn directly (no SwiftUI). Repainting one row is cheap.
final class ExplorerRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}        // Cell draws its own background.
    override func drawSelection(in dirtyRect: NSRect) {}         // Selection handled by the cell.
    override var isOpaque: Bool { false }
}

/// AppKit's concurrent scrolling animates its own backing layers. The Metal viewport
/// is a sibling, so it must receive the input position directly rather than sampling a
/// separately animated native layer. macOS still supplies trackpad momentum deltas.
final class ExplorerScrollView: NSScrollView {
    var usesMetalScrolling = false
    /// Trackpad input is drawn at the display's cadence (see `ScrollResampler`): a finger reports about 60 times
    /// a second, so moving the clip view on each event alone held every other 120 Hz frame still.
    private var resampler = ScrollResampler()
    private var targetY: CGFloat?
    private var drawnY: CGFloat?
    private var animating = false
    private var endPending = false

    override func scrollWheel(with event: NSEvent) {
        guard usesMetalScrolling, event.hasPreciseScrollingDeltas,
              event.modifierFlags.intersection([.command, .option, .shift]).isEmpty,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let center = NotificationCenter.default
        if event.phase.contains(.began) || event.momentumPhase.contains(.began) {
            // A new gesture while the previous one is still gliding continues the same live scroll.
            if endPending { endPending = false } else { center.post(name: NSScrollView.willStartLiveScrollNotification, object: self) }
        }
        queue(event.scrollingDeltaY, at: scrollInputTime(event, now: CACurrentMediaTime()))
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            if animating { endPending = true } else { center.post(name: NSScrollView.didEndLiveScrollNotification, object: self) }
        }
    }

    /// Moves immediately (programmatic scrolling and tests).
    func scrollPrecisely(by delta: CGFloat) {
        guard delta.isFinite, delta != 0 else { return }
        cancelGlide()
        var target = contentView.bounds
        target.origin.y -= delta
        target = contentView.constrainBoundsRect(target)
        guard target.origin != contentView.bounds.origin else { return }
        contentView.scroll(to: target.origin)
        reflectScrolledClipView(contentView)
    }

    private func cancelGlide() { resampler.reset(); targetY = nil; drawnY = nil }

    private func queue(_ delta: CGFloat, at time: Double) {
        guard delta.isFinite, delta != 0 else { return }
        let current = contentView.bounds.origin.y
        // Something else moved the content (keyboard, reveal, resize): start from where it is.
        if let drawnY, abs(current - drawnY) > 0.5 { cancelGlide() }
        let base = targetY ?? current
        var target = contentView.bounds
        target.origin.y = base - delta
        target = contentView.constrainBoundsRect(target)
        let applied = target.origin.y - base
        guard applied != 0 else { return }
        if targetY == nil { resampler.reset() }
        targetY = target.origin.y
        resampler.input(Double(applied), at: time)
        apply()
        startGliding()
    }

    private func apply() {
        guard let targetY else { return }
        let scale = window?.backingScaleFactor ?? 2
        // Whole device pixels keep text on the pixel grid, like the terminal's smooth scrolling.
        let y = ((targetY - CGFloat(resampler.lag)) * scale).rounded() / scale
        if y != contentView.bounds.origin.y {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
            reflectScrolledClipView(contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: self)
        }
        drawnY = contentView.bounds.origin.y
    }

    private func startGliding() {
        guard !animating, let frames = WindowFrameScheduler.forWindow(window) else { return }
        animating = true
        resampler.framePeriod = 1.0 / Double(max(30, frames.targetRate))
        frames.animate(ObjectIdentifier(self)) { [weak self] time in
            guard let self else { return false }
            guard time.isFinite, self.targetY != nil else { self.finishGlide(); return false }
            let active = self.resampler.advance(to: CACurrentMediaTime())
            self.apply()
            if !active { self.finishGlide() }
            return active
        }
    }

    private func finishGlide() {
        animating = false
        targetY = nil
        if endPending {
            endPending = false
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: self)
        }
    }
}

/// Fixed-height cells use direct frames and cached symbols, avoiding stack/constraint
/// changes as recycled rows alternate between folders, icons and language tags.
final class ExplorerCellView: NSTableCellView {
    private let chevron = NSImageView(), icon = NSImageView()
    private let abbreviation = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let diagnostics = NSTextField(labelWithString: "")
    private let gitBadge = NSTextField(labelWithString: "")
    private var current: ExplorerRow?
    private var renderedEntry: ExplorerRow?
    private let artwork = ExplorerCellArtwork()
    private(set) var metalCovered = false
    private var active = false, selected = false, hovered = false
    private static var symbols: [String: NSImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        abbreviation.font = .monospacedSystemFont(ofSize: 8, weight: .bold)
        abbreviation.alignment = .center
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        for field in [diagnostics, gitBadge] { field.font = .monospacedSystemFont(ofSize: 10, weight: .medium); field.alignment = .right }
        addSubview(artwork)
        for view in [chevron, icon, abbreviation, name, diagnostics, gitBadge] { artwork.addSubview(view); view.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !metalCovered else { return }
        artwork.frame = bounds
        let inset = 8 + CGFloat(current?.depth ?? 0) * 12
        chevron.frame = NSRect(x: inset, y: 8, width: 10, height: 8)
        icon.frame = NSRect(x: inset + 15, y: 4, width: 17, height: 16)
        abbreviation.frame = NSRect(x: inset + 15, y: 6, width: 17, height: 12)
        var right = bounds.width - 8
        for field in [gitBadge, diagnostics] where !field.isHidden {
            let width = ceil(field.intrinsicContentSize.width)
            field.frame = NSRect(x: right - width, y: 5, width: width, height: 15)
            right -= width + 7
        }
        let x = inset + 37
        name.frame = NSRect(x: x, y: 4, width: max(0, right - x), height: 17)
    }

    func configure(_ entry: ExplorerRow, active: Bool, selected: Bool, hovered: Bool) {
        let changed = current != entry
        guard changed || self.active != active || self.selected != selected || self.hovered != hovered else { return }
        current = entry
        self.active = active; self.selected = selected; self.hovered = hovered
        if changed {
            toolTip = entry.item.url.path + (entry.git.map { " — " + $0.label } ?? "")
            var description = entry.name
            if entry.item.isDirectory { description += entry.expanded ? ", expanded folder" : ", folder" }
            if let git = entry.git { description += ", " + git.label }
            if entry.diagnostics.count > 0 { description += ", \(entry.diagnostics.errors) errors, \(entry.diagnostics.warnings) warnings" }
            setAccessibilityLabel(description)
        }
        if !metalCovered { refreshArtwork() }
        setAccessibilitySelected(active || selected)
        paintBackground()
    }
    /// Keep the cell itself available to AppKit hit testing, drag/drop and accessibility.
    /// Layer opacity alone still lets AppKit rasterize every recycled row beneath Metal.
    func setMetalCovered(_ covered: Bool) {
        guard metalCovered != covered else { return }
        metalCovered = covered
        artwork.isHidden = covered
        if !covered { refreshArtwork(); needsLayout = true }
        paintBackground()
    }

    private func refreshArtwork() {
        guard let entry = current, renderedEntry != entry else { return }
        renderedEntry = entry
        let look = SemanticFileIcon.appearance(url: entry.item.url, directory: entry.item.isDirectory, expanded: entry.expanded)
        chevron.isHidden = !entry.item.isDirectory
        chevron.image = Self.symbol(entry.expanded ? "chevron.down" : "chevron.right", size: 8)
        chevron.contentTintColor = NSColor(NeoLinkTheme.textSecondary)
        icon.isHidden = look.abbreviation != nil
        abbreviation.isHidden = look.abbreviation == nil
        icon.image = Self.symbol(look.symbol, size: 12)
        icon.contentTintColor = NSColor(look.color)
        abbreviation.stringValue = look.abbreviation ?? ""
        abbreviation.textColor = NSColor(look.color)
        name.stringValue = entry.name
        name.textColor = NSColor(entry.git?.color ?? NeoLinkTheme.textPrimary)
        alphaValue = entry.git == .ignored ? 0.55 : 1
        diagnostics.isHidden = entry.diagnostics.count == 0
        diagnostics.stringValue = entry.diagnostics.count > 0 ? "\(entry.diagnostics.count)" : ""
        diagnostics.textColor = NSColor(entry.diagnostics.errors > 0 ? NeoLinkTheme.error : NeoLinkTheme.warning)
        gitBadge.isHidden = entry.git == nil || entry.git == .ignored
        gitBadge.stringValue = gitBadge.isHidden ? "" : entry.git?.rawValue ?? ""
        gitBadge.textColor = NSColor(entry.git?.color ?? NeoLinkTheme.textSecondary)
        needsLayout = true
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name):\(size)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        symbols[key] = image
        return image
    }
    func setHovered(_ hovered: Bool) { guard hovered != self.hovered else { return }; self.hovered = hovered; paintBackground() }
    private func paintBackground() {
        let color = metalCovered ? .clear : (active || selected ? NeoLinkTheme.selection : (hovered ? NeoLinkTheme.rowHoverWhite : .clear))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor(color).cgColor
        CATransaction.commit()
    }
}

private final class ExplorerCellArtwork: NSView {
    override var isFlipped: Bool { true }
}

/// Retained by an `NSMenuItem` (via `representedObject`) so a menu entry can run a Swift closure.
final class MenuActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}
