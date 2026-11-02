import AppKit
import PDFKit
import XCTest
@testable import NeoLink

final class DocumentTabsTests: XCTestCase {
    private func temporaryFile(_ name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor
    private func finishLoading(_ document: WorkspaceDocument) async throws {
        for _ in 0..<400 {
            if !document.isLoading { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Document load did not finish")
    }

    func testTextFormatsPreserveUnicodeByteOrderMarksAndLineEndings() throws {
        let text = "let greeting = \"héllo 🌎\"\r\n\tprint(greeting)\r\n"
        let formats: [(String.Encoding, Data)] = [(.utf8, Data()), (.utf8, Data([0xEF, 0xBB, 0xBF])),
                                                 (.utf16LittleEndian, Data([0xFF, 0xFE])), (.utf16BigEndian, Data([0xFE, 0xFF]))]
        for (encoding, mark) in formats {
            let bytes = mark + text.data(using: encoding)!
            let loaded = try DocumentFileIO.decode(bytes, name: "script.swift")
            XCTAssertEqual(loaded.text, text)
            XCTAssertEqual(try loaded.format?.encode(text), bytes)
        }
        XCTAssertEqual(try DocumentFileIO.decode(Data("FROM alpine\n".utf8), name: "Dockerfile").text, "FROM alpine\n")
        XCTAssertEqual(try DocumentFileIO.decode(Data(), name: "empty.py").text, "")
    }

    func testBinaryInvalidPDFAndOversizedFilesAreRejected() throws {
        XCTAssertThrowsError(try DocumentFileIO.decode(Data([0, 1, 2, 3]), name: "image.png"))
        XCTAssertThrowsError(try DocumentFileIO.decode(Data("not a PDF".utf8), name: "test.PDF"))
        let url = try temporaryFile("large.py", data: Data(repeating: 65, count: DocumentFileIO.sizeLimit(for: "large.py") + 1))
        XCTAssertThrowsError(try DocumentFileIO.read(url))
        XCTAssertThrowsError(try DocumentFileIO.read(url.deletingLastPathComponent()))
    }

    func testSavePreservesEncodingAndRefusesExternalChanges() throws {
        let original = Data([0xFF, 0xFE]) + "one\r\n".data(using: .utf16LittleEndian)!
        let url = try temporaryFile("file.py", data: original)
        let loaded = try DocumentFileIO.read(url)
        let format = try XCTUnwrap(loaded.format)
        let saved = try DocumentFileIO.save("two\r\n", format: format, to: url, originalData: original)
        XCTAssertEqual(saved, Data([0xFF, 0xFE]) + "two\r\n".data(using: .utf16LittleEndian)!)
        let external = try format.encode("external edit\r\n")
        try external.write(to: url)
        XCTAssertThrowsError(try DocumentFileIO.save("my edit", format: format, to: url, originalData: saved))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testOpeningFileDeduplicatesSymlinksAndRetainsOriginatingBrowser() async throws {
        let url = try temporaryFile("hello.swift", data: Data("print(42)\n".utf8))
        let link = url.deletingLastPathComponent().appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let tabs = TabsController(useNeovim: false)
        let terminal = try XCTUnwrap(tabs.selectedTerminalTab)
        tabs.openFile(url)
        let document = try XCTUnwrap(tabs.selectedTab?.document)
        defer { document.close() }
        try await finishLoading(document)
        XCTAssertEqual(document.text, "print(42)\n")
        XCTAssertEqual(tabs.browserTab?.id, terminal.id)
        XCTAssertFalse(terminal.state.hasStarted)
        tabs.openFile(link)
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertTrue(tabs.selectedTab?.document === document)
        tabs.selectPreviousTab()
        XCTAssertEqual(tabs.selectedTabID, terminal.id)
        tabs.selectNextTab()
        XCTAssertEqual(tabs.selectedTabID, document.id)
        tabs.closeTab(document.id)
        XCTAssertEqual(tabs.selectedTabID, terminal.id)
        XCTAssertFalse(terminal.state.isClosed)
    }

    @MainActor
    func testModifiedDocumentsStayOpenUntilSavedAndFailuresRetainEdits() async throws {
        let url = try temporaryFile("script.py", data: Data("print(1)\n".utf8))
        let tabs = TabsController(useNeovim: false)
        tabs.openFile(url)
        let document = try XCTUnwrap(tabs.selectedTab?.document)
        defer { document.close() }
        try await finishLoading(document)
        document.updateText("print(2)\n")
        tabs.closeTab(document.id)
        XCTAssertTrue(document.isModified)
        XCTAssertEqual(tabs.selectedTabID, document.id)
        let saved = await document.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(document.isModified)
        XCTAssertEqual(try String(contentsOf: url), "print(2)\n")
        document.updateText("print(3)\n")
        try Data("outside\n".utf8).write(to: url)
        let conflicted = await document.save()
        XCTAssertFalse(conflicted)
        XCTAssertTrue(document.isModified)
        XCTAssertEqual(document.text, "print(3)\n")
        XCTAssertNotNil(document.error)
        XCTAssertEqual(try String(contentsOf: url), "outside\n")
        tabs.closeTab(document.id, discardingChanges: true)
        XCTAssertEqual(tabs.tabs.count, 1)
    }

    @MainActor
    func testAgentEditsRefreshCleanNativeBuffersAndPreserveDirtyBuffers() async throws {
        let url = try temporaryFile("agent.txt", data: Data("before\n".utf8))
        let document = WorkspaceDocument(url: url, browserTabID: nil)
        defer { document.close() }
        document.load()
        try await finishLoading(document)
        let view = try XCTUnwrap(document.makeEditor().documentView as? NSTextView)
        try Data("from agent\n".utf8).write(to: url)
        await document.refreshFromDiskIfUnmodified()
        XCTAssertEqual(document.text, "from agent\n")
        XCTAssertEqual(view.string, "from agent\n")
        XCTAssertFalse(document.isModified)
        document.updateText("my unsaved edit\n")
        try Data("new agent edit\n".utf8).write(to: url)
        await document.refreshFromDiskIfUnmodified()
        XCTAssertEqual(document.text, "my unsaved edit\n")
        XCTAssertTrue(document.isModified)
        let saved = await document.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: url), "new agent edit\n")
    }

    @MainActor
    func testNativeEditorKeepsSelectionAndUndoWhenReused() async throws {
        let url = try temporaryFile("file.txt", data: Data("hello\n".utf8))
        let document = WorkspaceDocument(url: url, browserTabID: nil)
        defer { document.close() }
        document.load()
        try await finishLoading(document)
        let scroll = document.makeEditor()
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        view.insertText("world", replacementRange: NSRange(location: 0, length: 5))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(document.text, "world\n")
        XCTAssertTrue(document.isModified)
        XCTAssertTrue(document.makeEditor() === scroll)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "hello\n")
        XCTAssertFalse(document.isModified)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
    }

    @MainActor
    func testPDFLoadsInNativeViewerAndPreservesPageSelection() async throws {
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        pdf.insert(PDFPage(), at: 1)
        let url = try temporaryFile("guide.PDF", data: XCTUnwrap(pdf.dataRepresentation()))
        let tabs = TabsController(useNeovim: false)
        tabs.openFile(url)
        let document = try XCTUnwrap(tabs.selectedTab?.document)
        defer { document.close() }
        try await finishLoading(document)
        XCTAssertNil(document.error)
        let view = try XCTUnwrap(document.pdfView)
        XCTAssertEqual(view.document?.pageCount, 2)
        view.go(to: try XCTUnwrap(view.document?.page(at: 1)))
        tabs.selectPreviousTab()
        tabs.selectNextTab()
        XCTAssertTrue(tabs.selectedTab?.document?.pdfView === view)
        let currentPage = try XCTUnwrap(view.currentPage)
        XCTAssertEqual(view.document?.index(for: currentPage), 1)
        XCTAssertTrue(document.isReadOnly)
    }

    @MainActor
    func testClosingLoadingFileDoesNotReplaceCurrentTabLater() async throws {
        let url = try temporaryFile("script.js", data: Data("console.log('hello')".utf8))
        let tabs = TabsController(useNeovim: false)
        let terminalID = tabs.selectedTabID
        tabs.openFile(url)
        let document = try XCTUnwrap(tabs.selectedTab?.document)
        tabs.closeTab(document.id)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(tabs.selectedTabID, terminalID)
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertNil(document.loaded)
    }
}
