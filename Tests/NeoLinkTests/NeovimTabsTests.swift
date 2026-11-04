import AppKit
import SwiftUI
import XCTest
@testable import NeoLink

final class NeovimTabsTests: XCTestCase {
    @MainActor
    func testStaleRedrawMarkersAndResponsesCannotExposeOrSelectAnObsoleteFile() {
        let session = NeovimSession(executable: nil)
        var selected: String? = "/tmp/first.txt"
        session.selectedPath = { selected }
        session.prepareSelection(selected)
        let oldToken = session.selectionToken
        selected = "/tmp/last.txt"
        session.prepareSelection(selected)
        session.selectionParsed(oldToken)
        XCTAssertEqual(session.requestedPath, selected)
        let stale = NeovimSnapshot(revision: 20, buffers: [], active: "/tmp/first.txt", mode: "i", unnamedModified: false, selection: oldToken)
        XCTAssertFalse(session.canAdoptSelection(stale))
        session.selectionParsed(session.selectionToken)
        XCTAssertNil(session.requestedPath)
        XCTAssertFalse(session.canAdoptSelection(stale), "An older response cannot select its old tab after the latest redraw")
        session.prepareSelection(nil)
        session.selectionParsed(oldToken)
        XCTAssertNil(session.requestedPath, "An old editor callback cannot restore focus after selecting the shell")
    }

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
    @MainActor
    func testRapidSelectionsCoalesceAndKeepDirtyBufferThroughSaveAndClose() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-switch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let files = (0..<3).map { root.appendingPathComponent("file-\($0).txt") }
        for file in files { try Data("original\n".utf8).write(to: file) }
        let controller = TabsController()
        defer { controller.codeSession.shutdown(); try? FileManager.default.removeItem(at: root) }
        for file in files { controller.openFile(file) }
        try await settle { controller.tabs.compactMap(\.document).allSatisfy { !$0.isLoading } && controller.codeSession.requestedPath == nil }
        let editor = try XCTUnwrap(controller.codeSession.terminal)
        editor.send(txt: "changed ")
        try await settle { controller.selectedTab?.document?.isModified == true }
        let dirty = try XCTUnwrap(controller.selectedTab?.document)
        let documents = controller.tabs.compactMap(\.document)
        let before = controller.codeSession.dispatchedRequests
        for index in 0..<90 { controller.selectedTabID = documents[index % 3].id }
        controller.selectedTabID = documents[0].id
        try await settle { controller.codeSession.requestedPath == nil && controller.codeSession.snapshot?.active == files[0].path }
        XCTAssertEqual(controller.selectedTabID, documents[0].id)
        XCTAssertGreaterThan(controller.codeSession.skippedSelections, 70)
        XCTAssertLessThan(controller.codeSession.dispatchedRequests - before, 10)
        XCTAssertTrue(dirty.isModified, "Switching must retain unsaved buffers")
        let saved = await controller.codeSession.save(files[2])
        XCTAssertTrue(saved)
        XCTAssertTrue(try String(contentsOf: files[2]).contains("changed"))
        controller.closeTab(dirty.id, discardingChanges: true)
        _ = await controller.codeSession.refresh()
        XCTAssertFalse(controller.tabs.contains { $0.id == dirty.id })
        XCTAssertFalse(controller.codeSession.snapshot?.buffers.contains { $0.path == files[2].path } ?? true)
        XCTAssertEqual(controller.selectedTabID, documents[0].id)
        XCTAssertNil(controller.codeSession.error)
    }

    @MainActor
    func testHiddenEditorKeepsItsFrameAndGridAcrossShellRoundTrip() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("example.txt")
        try Data("retained grid\n".utf8).write(to: file)
        let controller = TabsController()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabbedTerminalView(controller: controller))
        defer { controller.codeSession.shutdown(); controller.tabs.compactMap(\.terminal).forEach { $0.state.close() }; window.close(); try? FileManager.default.removeItem(at: root) }
        window.makeKeyAndOrderFront(nil)
        controller.openFile(file)
        let documentID = try XCTUnwrap(controller.selectedTabID)
        try await settle { controller.codeSession.requestedPath == nil && controller.codeSession.terminal?.isHidden == false }
        try await Task.sleep(nanoseconds: 100_000_000)
        let terminal = try XCTUnwrap(controller.codeSession.terminal)
        let frame = terminal.frame, rows = terminal.getTerminal().rows
        controller.selectedTabID = controller.workspaceTerminalTabs.first?.id
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(terminal.frame, frame, "Hidden chrome must not enlarge the editor")
        XCTAssertEqual(terminal.getTerminal().rows, rows)
        controller.selectedTabID = documentID
        try await settle { controller.codeSession.requestedPath == nil && !terminal.isHidden }
        XCTAssertEqual(terminal.frame, frame)
        XCTAssertEqual(terminal.getTerminal().rows, rows)
    }

    @MainActor
    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Editor did not settle before deadline")
    }

}
