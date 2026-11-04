import AppKit
import SwiftUI
import XCTest
@testable import NeoLink

final class TabPresentationTests: XCTestCase {
    func testLongExplorerNamesFitWithoutSelectedOrDirtyGeometry() {
        let titles = ["ExplorerMetalView.swift", "ExplorerTableView.swift", "Local"]
        let models = TabPresentation.make(titles: titles, paths: ["/src/ExplorerMetalView.swift", "/src/ExplorerTableView.swift", nil])
        XCTAssertEqual(models.map(\.title), titles)
        XCTAssertNotEqual(models[0].width, 156)
        for model in models {
            XCTAssertGreaterThanOrEqual(model.width, TabPresentation.minimumWidth)
            XCTAssertLessThanOrEqual(model.width, TabPresentation.maximumWidth)
            XCTAssertGreaterThanOrEqual(model.width, TabPresentation.measure(model.title) + TabPresentation.chromeWidth)
        }
        XCTAssertEqual(models, TabPresentation.make(titles: titles, paths: ["/src/ExplorerMetalView.swift", "/src/ExplorerTableView.swift", nil]), "UI state is deliberately absent from geometry inputs")
    }
    func testDuplicateBasenamesUseMinimalDistinctParentSuffix() {
        let result = TabPresentation.make(titles: ["index.ts", "index.ts", "readme.md"], paths: ["/repo/client/src/index.ts", "/repo/server/src/index.ts", "/repo/readme.md"])
        XCTAssertEqual(result.map(\.context), ["client/src", "server/src", ""])
        XCTAssertEqual(result.map(\.title), ["index.ts", "index.ts", "readme.md"])
    }
    func testLongDuplicateParentContextRemainsDistinctWhenCompressed() {
        let shared = String(repeating: "common/", count: 12)
        let models = TabPresentation.make(titles: ["index.ts", "index.ts"], paths: ["/client/" + shared + "index.ts", "/server/" + shared + "index.ts"])
        XCTAssertNotEqual(models[0].context, models[1].context)
        XCTAssertTrue(models[0].context.contains("client"))
        XCTAssertTrue(models[1].context.contains("server"))
        XCTAssertTrue(models.allSatisfy { TabPresentation.measure($0.context) <= 100 })
    }
    func testTruncationRetainsDistinguishingMiddleAndExtension() {
        let stem = String(repeating: "VeryLongCommonName", count: 8)
        let titles = [stem + "Alpha" + stem + ".swift", stem + "Bravo" + stem + ".swift"]
        let models = TabPresentation.make(titles: titles, paths: [nil, nil])
        XCTAssertNotEqual(models[0].title, models[1].title)
        XCTAssertTrue(models[0].title.contains("Alpha"))
        XCTAssertTrue(models[1].title.contains("Bravo"))
        XCTAssertTrue(models.allSatisfy { $0.title.hasSuffix(".swift") && $0.width <= TabPresentation.maximumWidth })
    }
    func testNearestRevealDoesNotMoveVisibleTabsAndUsesMinimalEdge() {
        let viewport = CGRect(x: 100.5, y: 0, width: 300, height: 34)
        XCTAssertEqual(TabPresentation.revealOrigin(item: .init(x: 150, y: 0, width: 180, height: 34), viewport: viewport, contentWidth: 1000), 100.5)
        XCTAssertEqual(TabPresentation.revealOrigin(item: .init(x: 50, y: 0, width: 180, height: 34), viewport: viewport, contentWidth: 1000), 50)
        XCTAssertEqual(TabPresentation.revealOrigin(item: .init(x: 350, y: 0, width: 180, height: 34), viewport: viewport, contentWidth: 1000), 230)
        XCTAssertEqual(TabPresentation.revealOrigin(item: .init(x: 800, y: 0, width: 500, height: 34), viewport: viewport, contentWidth: 1000), 700)
    }
    @MainActor
    func testNativeStripKeepsFractionalOriginForVisibleSelection() {
        _ = NSApplication.shared
        let scroll = TabStripScrollView(content: SwiftUI.Text("tabs"))
        scroll.frame = .init(x: 0, y: 0, width: 300, height: 34)
        scroll.contentWidth = 1000
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .init(x: 100.5, y: 0))
        scroll.reveal = .init(x: 150, y: 0, width: 180, height: 34)
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minX, 100.5, accuracy: 0.01)
        scroll.reveal = .init(x: 700, y: 0, width: 180, height: 34)
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.maxX, 880, accuracy: 0.01)
    }
    @MainActor
    func testRedrawGateHidesSynchronouslyAndRejectsObsoleteReady() {
        _ = NSApplication.shared
        let session = NeovimSession(executable: nil)
        var path: String? = "/tmp/A.swift"
        session.selectedPath = { path }
        let host = NeovimHostView()
        host.synchronize(session: session, active: true, selection: UUID())
        session.prepareSelection(path)
        let old = session.selectionToken
        path = "/tmp/B.swift"; session.prepareSelection(path)
        session.selectionParsed(old)
        XCTAssertNotNil(session.requestedPath)
        session.selectionParsed(session.selectionToken)
        XCTAssertNil(session.requestedPath)
        path = nil; session.prepareSelection(nil)
        session.selectionParsed(old)
        XCTAssertEqual(session.selectionToken, old + 2)
    }
}
