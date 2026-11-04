import AppKit
import Metal
import XCTest
@testable import NeoLink

@MainActor
private final class RecordingExplorerTable: NSTableView {
    var reloads = 0
    var forcedVisibleRows: NSRange?
    var beforeMutation: (() -> Void)?
    override func rows(in rect: NSRect) -> NSRange { forcedVisibleRows ?? super.rows(in: rect) }
    override func beginUpdates() { beforeMutation?(); super.beginUpdates() }
    override func reloadData() { reloads += 1; super.reloadData() }
}

@MainActor
private final class ScrollTestDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ExplorerTableTests: XCTestCase {
    @MainActor
    func testEmptyProjectInvalidatesGPUStateBeforeNativeTableMutation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let previous = TerminalRenderingPreferences.shared.useGPU
        TerminalRenderingPreferences.shared.setUseGPU(true)
        let (coordinator, table, scroll) = setup()
        defer { coordinator.stopObservingScrolling(); TerminalRenderingPreferences.shared.setUseGPU(previous) }
        coordinator.apply(rows: (0..<40).map { row("\($0).swift") }, revision: 1, activeFileURL: nil)
        coordinator.installMetalSurface()
        let deadline = Date(timeIntervalSinceNow: 10)
        while coordinator.metalSurface == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let surface = try XCTUnwrap(coordinator.metalSurface)
        let before = surface.visualRevision
        var mutations = 0
        table.beforeMutation = {
            mutations += 1
            XCTAssertGreaterThan(surface.visualRevision, before, "Retire row indices before AppKit can reenter rendering")
        }
        table.forcedVisibleRows = NSRange(location: 0, length: 0)
        coordinator.apply(rows: [], revision: 2, activeFileURL: nil)
        XCTAssertGreaterThan(mutations, 0)
        XCTAssertGreaterThan(surface.visualRevision, before)
        XCTAssertTrue(coordinator.rows.isEmpty)
        let emptyRevision = surface.visualRevision
        coordinator.apply(rows: [], revision: 2, activeFileURL: row("previous.swift").id)
        XCTAssertGreaterThan(surface.visualRevision, emptyRevision, "An empty native viewport must still wake highlight/fallback updates")
        _ = scroll // Retain the input surface until the coordinator is shut down.
    }

    @MainActor
    func testShrinkingProjectToleratesNativeVisibleRangeBeyondItsNewEnd() {
        let (coordinator, table, scroll) = setup()
        defer { coordinator.stopObservingScrolling() }
        coordinator.apply(rows: (0..<100).map { row("\($0).swift") }, revision: 1, activeFileURL: nil)
        table.forcedVisibleRows = NSRange(location: 80, length: 5)
        coordinator.apply(rows: [row("new.swift")], revision: 2, activeFileURL: nil)
        XCTAssertEqual(coordinator.rows.count, 1)
        XCTAssertEqual(table.numberOfRows, 1)
        _ = scroll
    }

    private func row(_ name: String, depth: Int = 0, folder: Bool = false, expanded: Bool = false,
                     missing: Bool = false, errors: Int = 0, warnings: Int = 0) -> ExplorerRow {
        let url = URL(fileURLWithPath: "/tmp/NeoLink-table-tests/" + name)
        return ExplorerRow(id: url, item: LocalFileItem(url: url, isDirectory: folder, creationDate: nil, modificationDate: nil, fileSize: nil),
                           name: name, depth: depth, expanded: expanded, missing: missing, git: .modified,
                           diagnostics: ExplorerDiagnostics(errors: errors, warnings: warnings))
    }

    @MainActor
    private func setup(toggle: @escaping (ExplorerRow) -> Void = { _ in },
                       open: @escaping (LocalFileItem) -> Void = { _ in },
                       drop: @escaping (ExplorerRow?, [URL]) -> Bool = { _, _ in true })
    -> (ExplorerTableView.Coordinator, RecordingExplorerTable, NSScrollView) {
        _ = NSApplication.shared
        let parent = ExplorerTableView(tree: ExplorerTree(), activeFileURL: nil, onToggle: toggle, onOpen: open,
            contextMenu: { _ in NSMenu() }, canAcceptDrop: { _, _ in true }, onDrop: drop)
        let coordinator = parent.makeCoordinator()
        let table = RecordingExplorerTable(frame: NSRect(x: 0, y: 0, width: 300, height: 2400))
        table.headerView = nil; table.rowHeight = 24; table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = coordinator; table.delegate = coordinator
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        scroll.documentView = table
        coordinator.table = table; coordinator.observeScrolling(in: scroll)
        return (coordinator, table, scroll)
    }

    @MainActor
    func testRevealLeavesVisibleRowsStationaryAndMovesOnlyToTheNearestEdge() {
        let (coordinator, table, scroll) = setup()
        let rows = (0..<100).map { row("\($0).swift") }
        coordinator.apply(rows: rows, revision: 1, activeFileURL: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30 * 24 + 7))
        let original = scroll.contentView.bounds.minY
        coordinator.revealIfNeeded(revision: 1, file: rows[32].id)
        XCTAssertEqual(scroll.contentView.bounds.minY, original, accuracy: 0.01)
        coordinator.revealIfNeeded(revision: 2, file: rows[30].id)
        XCTAssertEqual(scroll.contentView.bounds.minY, 30 * 24, accuracy: 0.01)
        coordinator.revealIfNeeded(revision: 3, file: rows[40].id)
        XCTAssertEqual(scroll.contentView.bounds.maxY, 41 * 24, accuracy: 0.01)
        XCTAssertEqual(table.numberOfRows, 100)
    }

    @MainActor
    func testAsyncRevealCannotOverrideASubsequentScrollGesture() throws {
        let (coordinator, _, scroll) = setup()
        // Use the tree's real request revision, which is issued before async loading.
        let root = URL(fileURLWithPath: "/tmp/NeoLink-table-tests")
        coordinator.parent.tree.configure(root: root, hidden: true, compact: false, hideIgnored: false)
        let rows = (0..<100).map { row("\($0).swift") }
        coordinator.apply(rows: Array(rows.prefix(80)), revision: 1, activeFileURL: nil)
        coordinator.parent.tree.reveal(rows[90].id)
        let revision = coordinator.parent.tree.revealRevision
        XCTAssertGreaterThan(revision, 0)
        coordinator.revealIfNeeded(revision: revision, file: rows[90].id) // Not loaded yet.
        coordinator.scrollBegan()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30 * 24 + 7))
        coordinator.apply(rows: rows, revision: 2, activeFileURL: nil)
        coordinator.finishScrolling()
        coordinator.revealIfNeeded(revision: revision, file: rows[90].id)
        XCTAssertEqual(scroll.contentView.bounds.minY, 30 * 24 + 7, accuracy: 0.01)
        coordinator.revealIfNeeded(revision: revision + 1, file: rows[90].id)
        XCTAssertEqual(scroll.contentView.bounds.maxY, 91 * 24, accuracy: 0.01, "A fresh explicit reveal still works")
    }

    @MainActor
    func testCollapseAnchorsToTheVisibleChildsSurvivingParent() {
        let (coordinator, _, scroll) = setup()
        let prefix = (0..<20).map { row("before-\($0).swift") }
        let folder = row("src", folder: true, expanded: true)
        let children = (0..<30).map { row("child-\($0).swift", depth: 1) }
        let suffix = (0..<30).map { row("after-\($0).swift") }
        coordinator.apply(rows: prefix + [folder] + children + suffix, revision: 1, activeFileURL: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 25 * 24 + 7))
        coordinator.apply(rows: prefix + [row("src", folder: true)] + suffix, revision: 2, activeFileURL: nil)
        XCTAssertEqual(scroll.contentView.bounds.minY, 20 * 24 + 7, accuracy: 0.01)
        coordinator.apply(rows: prefix + [row("src", folder: true, errors: 3)] + suffix, revision: 3, activeFileURL: nil)
        XCTAssertEqual(scroll.contentView.bounds.minY, 20 * 24 + 7, accuracy: 0.01)
    }

    @MainActor
    func testDragValidationNeverCopiesAndAcceptanceCopiesOnce() {
        var copies = 0, target: URL?
        let (coordinator, table, scroll) = setup(drop: { entry, _ in copies += 1; target = entry?.item.url; return true })
        _ = (table, scroll)
        let folder = row("folder", folder: true)
        coordinator.apply(rows: [folder, row("gone", folder: true, missing: true)], revision: 1, activeFileURL: nil)
        let urls = [URL(fileURLWithPath: "/tmp/source.txt")]
        for _ in 0..<50 { XCTAssertTrue(coordinator.canDrop(row: 0, operation: .on, urls: urls)) }
        XCTAssertEqual(copies, 0)
        XCTAssertTrue(coordinator.performDrop(row: 0, operation: .on, urls: urls))
        XCTAssertEqual(copies, 1); XCTAssertEqual(target, folder.item.url)
        XCTAssertFalse(coordinator.canDrop(row: 1, operation: .on, urls: urls))
        XCTAssertFalse(coordinator.canDrop(row: -1, operation: .on, urls: []))
        XCTAssertFalse(coordinator.canDrop(row: -1, operation: .on, urls: [URL(string: "https://example.invalid/file")!]))
        XCTAssertEqual(copies, 1)
    }

    @MainActor
    func testInsertionPreservesSelectedIdentityAndFractionalViewportAnchor() {
        let (coordinator, table, scroll) = setup()
        let original = (0..<100).map { row(String(format: "%03d.swift", $0)) }
        coordinator.apply(rows: original, revision: 1, activeFileURL: nil)
        table.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30 * 24 + 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        let reloads = table.reloads
        coordinator.apply(rows: [row("inserted-a"), row("inserted-b")] + original, revision: 2, activeFileURL: nil)
        XCTAssertEqual(table.reloads, reloads)
        XCTAssertEqual(coordinator.rows[table.selectedRow].id, original[40].id)
        XCTAssertEqual(scroll.contentView.bounds.minY, 32 * 24 + 7, accuracy: 0.5)
        coordinator.apply(rows: coordinator.rows, revision: 2, activeFileURL: original[70].item.url)
        XCTAssertEqual(table.reloads, reloads)
        XCTAssertEqual(scroll.contentView.bounds.minY, 32 * 24 + 7, accuracy: 0.5)
    }

    @MainActor
    func testActiveSelectionWaitsForTheRevealedBranchToLoad() {
        let (coordinator, table, scroll) = setup()
        _ = scroll
        let folder = row("src", folder: true), file = row("main.swift", depth: 1)
        coordinator.apply(rows: [folder], revision: 1, activeFileURL: nil)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.apply(rows: [folder], revision: 1, activeFileURL: file.item.url)
        coordinator.apply(rows: [row("src", folder: true, expanded: true), file], revision: 2, activeFileURL: file.item.url)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(coordinator.rows[table.selectedRow].item.url, file.item.url)
    }

    @MainActor
    func testLiveScrollCoalescesBackgroundSnapshotsAndPreservesTheFinalAnchor() {
        let (coordinator, table, scroll) = setup()
        let original = (0..<100).map { row(String(format: "%03d.swift", $0)) }
        coordinator.apply(rows: original, revision: 1, activeFileURL: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30 * 24 + 7))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let reloads = table.reloads
        for revision in 2...50 {
            coordinator.apply(rows: [row("inserted-\(revision)")] + original, revision: revision, activeFileURL: nil)
        }
        XCTAssertEqual(coordinator.rows, original, "No membership or decoration changes during the gesture")
        XCTAssertEqual(table.reloads, reloads)
        // Momentum advances while the old snapshot remains visible. Anchor at its final
        // position, not the position when the first deferred refresh arrived.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40 * 24 + 11))
        coordinator.finishScrolling()
        XCTAssertEqual(coordinator.rows.first?.name, "inserted-50")
        XCTAssertEqual(scroll.contentView.bounds.minY, 41 * 24 + 11, accuracy: 0.5)
        XCTAssertEqual(table.reloads, reloads)
    }

    @MainActor
    func testExplicitEditorSelectionBypassesDeferredUpdates() {
        let (coordinator, table, scroll) = setup()
        _ = scroll
        let original = (0..<10).map { row("\($0).swift") }
        coordinator.apply(rows: original, revision: 1, activeFileURL: nil)
        coordinator.scrollBegan()
        coordinator.apply(rows: [row("new.swift")] + original, revision: 2, activeFileURL: nil)
        coordinator.apply(rows: [row("new.swift")] + original, revision: 2, activeFileURL: original[7].id)
        XCTAssertFalse(coordinator.deferringUpdates)
        XCTAssertEqual(coordinator.rows[table.selectedRow].id, original[7].id)
        coordinator.finishScrolling()
        XCTAssertEqual(coordinator.rows[table.selectedRow].id, original[7].id, "An old deferred snapshot cannot undo selection")
    }

    @MainActor
    func testEndNotificationFlushesAndDismantlingCancelsPendingWork() async throws {
        let (coordinator, table, scroll) = setup()
        _ = table
        coordinator.apply(rows: [row("a.swift")], revision: 1, activeFileURL: nil)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        coordinator.apply(rows: [row("b.swift")], revision: 2, activeFileURL: nil)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertEqual(coordinator.rows.first?.name, "a.swift")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(coordinator.rows.first?.name, "b.swift")
        coordinator.scrollBegan()
        coordinator.apply(rows: [row("c.swift")], revision: 3, activeFileURL: nil)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        coordinator.stopObservingScrolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(coordinator.rows.first?.name, "b.swift")
    }

    @MainActor
    func testDecorationChangeReusesCellAndDistinguishesErrorsFromWarnings() throws {
        let (coordinator, table, scroll) = setup()
        _ = scroll
        coordinator.apply(rows: [row("main.swift", warnings: 1)], revision: 1, activeFileURL: nil)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ExplorerCellView)
        XCTAssertTrue(cell.accessibilityLabel()?.contains("0 errors, 1 warnings") == true)
        let reloads = table.reloads
        coordinator.apply(rows: [row("main.swift", errors: 1)], revision: 2, activeFileURL: nil)
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === cell)
        XCTAssertTrue(cell.accessibilityLabel()?.contains("1 errors, 0 warnings") == true)
        XCTAssertEqual(table.reloads, reloads)
        let fields = cell.subviews.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(fields.contains("1")); XCTAssertTrue(fields.contains("M"), "Git and diagnostic badges coexist")
        coordinator.setHovered(0); coordinator.setHovered(nil)
        XCTAssertEqual(table.reloads, reloads)
    }

    @MainActor
    func testDirectTrackpadPositionIsBoundedAndReversesWithoutAnAnimationQueue() {
        _ = NSApplication.shared
        let scroll = ExplorerScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let document = ScrollTestDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 2400))
        scroll.documentView = document
        scroll.scrollPrecisely(by: -35)
        XCTAssertEqual(scroll.contentView.bounds.minY, 35, accuracy: 0.01)
        scroll.scrollPrecisely(by: 10)
        XCTAssertEqual(scroll.contentView.bounds.minY, 25, accuracy: 0.01)
        scroll.scrollPrecisely(by: 10_000)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        scroll.scrollPrecisely(by: -10_000)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 0.01)
        let parked = scroll.contentView.bounds
        scroll.scrollPrecisely(by: .nan)
        XCTAssertEqual(scroll.contentView.bounds, parked)
    }

    @MainActor
    func testCoveredCellReuseKeepsAccessibilityAndRestoresNewestNativeArtwork() throws {
        _ = NSApplication.shared
        let cell = ExplorerCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        cell.configure(row("old.swift"), active: false, selected: false, hovered: false)
        cell.setMetalCovered(true)
        cell.configure(row("new.swift", errors: 2), active: true, selected: true, hovered: false)
        XCTAssertFalse(cell.isHidden, "The interaction/accessibility cell must remain available")
        XCTAssertTrue(cell.accessibilityLabel()?.contains("new.swift") == true)
        XCTAssertTrue(cell.accessibilityLabel()?.contains("2 errors") == true)
        XCTAssertTrue(cell.isAccessibilitySelected())
        let artwork = try XCTUnwrap(cell.subviews.first)
        XCTAssertTrue(artwork.isHidden, "Covered native artwork must not be rasterized")
        let fields = artwork.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == "old.swift" }, "Row reuse defers invisible artwork updates")
        cell.setMetalCovered(false)
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(artwork.isHidden)
        XCTAssertTrue(fields.contains { $0.stringValue == "new.swift" })
        XCTAssertTrue(fields.contains { $0.stringValue == "2" })
        XCTAssertEqual(artwork.frame, cell.bounds)
        XCTAssertTrue(fields.filter { !$0.isHidden }.allSatisfy { $0.frame.height > 0 })
    }

    @MainActor
    func testKeyboardFolderNavigationAndSelectionSurviveCollapse() {
        var toggled: [URL] = [], opened: [URL] = []
        let (coordinator, table, scroll) = setup(toggle: { toggled.append($0.id) }, open: { opened.append($0.url) })
        _ = scroll
        let folder = row("src", folder: true, expanded: true), child = row("main.swift", depth: 1)
        coordinator.apply(rows: [folder, child], revision: 1, activeFileURL: nil)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.navigate(right: true)
        XCTAssertEqual(table.selectedRow, 1)
        coordinator.activate(table.selectedRow)
        XCTAssertEqual(opened, [child.item.url])
        coordinator.navigate(right: false)
        XCTAssertEqual(table.selectedRow, 0)
        coordinator.navigate(right: false)
        XCTAssertEqual(toggled, [folder.id])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.apply(rows: [row("src", folder: true)], revision: 2, activeFileURL: nil)
        XCTAssertEqual(table.selectedRow, 0)
        coordinator.activate(-1) // Empty-space clicks are harmless.
    }

    func testGeometrySamplerRejectsStationaryContentAndCountsLongPauses() {
        let still = (0..<350).map { (time: Double($0) / 120, y: $0 == 0 ? 0.0 : 1.0) }
        XCTAssertNotNil(ScrollGeometryMetrics.report(still, rate: 120)["invalid"])
        var positions = (0..<30).map { (time: Double($0) / 120, y: Double($0) * 6) }
        positions += (30..<40).map { (time: Double($0) / 120, y: 174.0) }
        for index in 40..<70 { positions.append((time: Double(index) / 120.0, y: 174.0 + Double(index - 39) * 6.0)) }
        let metrics = ScrollGeometryMetrics.report(positions, rate: 120)
        XCTAssertNil(metrics["invalid"])
        XCTAssertGreaterThan(metrics["scrollLongestStillMs"] as? Double ?? 0, 70)
        XCTAssertEqual(metrics["scrollRefreshesRepeatedWhileMoving"] as? Int, 10)
    }
}
