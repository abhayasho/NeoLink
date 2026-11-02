import AppKit
import XCTest
@testable import NeoLink

final class NeovimTabsTests: XCTestCase {
    @MainActor
    func testRapidOpeningKeepsFinalSelectionAndSharesEditor() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkTabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var files = ["one.txt", "two.txt", "three.txt"].map { root.appendingPathComponent($0) }
        for (i, file) in files.enumerated() { try Data("file \(i)\n".utf8).write(to: file) }
        files = files.map { $0.resolvingSymlinksInPath() }
        let controller = TabsController()
        defer { controller.codeSession.shutdown() }
        files.forEach(controller.openFile)
        let expected = try XCTUnwrap(controller.selectedTab?.id)
        for _ in 0..<600 {
            if controller.tabs.compactMap(\.document).allSatisfy({ !$0.isLoading }), controller.codeSession.snapshot?.active == files.last?.path { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(controller.codeSession.error)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.selectedTabID, expected)
        XCTAssertEqual(controller.codeSession.snapshot?.active, files.last?.path)
        XCTAssertEqual(controller.codeSession.snapshot?.buffers.count, 3)
        XCTAssertEqual(controller.tabs.compactMap(\.document).count, 3)
        XCTAssertTrue(controller.tabs.compactMap(\.document).allSatisfy { $0.neovim === controller.codeSession })
        controller.openFile(files[0])
        for _ in 0..<200 {
            if controller.codeSession.snapshot?.active == files[0].path { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.selectedTab?.document?.source, .local(files[0]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.codeSession.snapshot?.active, files[0].path)
        XCTAssertEqual(controller.tabs.compactMap(\.document).count, 3)
    }
}
