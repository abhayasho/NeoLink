import XCTest
@testable import NeoLink

final class LocalFileBrowserTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCopyInSameDirectoryPreservesOriginalAndMakesUniqueCopies() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        let original = Data("keep this document".utf8)
        try original.write(to: source)
        let operations = LocalFileOperations()

        let firstCopy = try await operations.copy(source, into: directory)
        let secondCopy = try await operations.copy(source, into: directory)

        XCTAssertEqual(firstCopy.lastPathComponent, "notes copy.txt")
        XCTAssertEqual(secondCopy.lastPathComponent, "notes copy 2.txt")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: firstCopy), original)
        XCTAssertEqual(try Data(contentsOf: secondCopy), original)
    }

    func testCopyNeverOverwritesAnExistingDestination() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("notes.txt")
        let existing = destination.appendingPathComponent("notes.txt")
        try Data("incoming".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)

        let copy = try await LocalFileOperations().copy(source, into: destination)

        XCTAssertEqual(copy.lastPathComponent, "notes copy.txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "incoming")
    }

    func testCopyRejectsFolderIntoItsOwnDescendant() async throws {
        let directory = try temporaryDirectory()
        let child = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        do {
            try await LocalFileOperations().copy(directory, into: child)
            XCTFail("Copying a folder into itself must fail")
        } catch LocalFileError.copyIntoItself {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
        }
    }

    func testRenameRejectsInvalidAndExistingNamesWithoutChangingFiles() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        let existing = directory.appendingPathComponent("existing.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)
        let operations = LocalFileOperations()

        for name in ["", "  ", ".", "..", "../escaped.txt", "child/file.txt"] {
            do {
                try await operations.rename(source, to: name)
                XCTFail("Invalid name was accepted: \(name)")
            } catch LocalFileError.invalidName {}
        }
        do {
            try await operations.rename(source, to: "existing.txt")
            XCTFail("An existing file must not be replaced")
        } catch LocalFileError.existingName {}

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
    }

    func testItemIdentityIsStableAcrossDirectoryLoads() throws {
        let directory = try temporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("file.txt"))

        let first = try LocalFileOperations.contents(at: directory, showHiddenFiles: false)
        let second = try LocalFileOperations.contents(at: directory, showHiddenFiles: false)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    @MainActor
    func testPasteInCurrentDirectoryKeepsSourceAndRefreshesListing() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: source)
        let browser = LocalFileBrowserViewModel(startingAt: directory)
        try await waitForIdle(browser)
        let item = try XCTUnwrap(browser.items.first)
        browser.copy(item: item)

        browser.paste()
        try await waitForIdle(browser)

        XCTAssertNil(browser.lastError)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(Set(browser.items.map { $0.url.lastPathComponent }), ["file.txt", "file copy.txt"])
    }

    @MainActor
    func testRapidNavigationPublishesOnlyLatestDirectoryAndCanResumeFollowingTerminal() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("first", isDirectory: true)
        let latest = directory.appendingPathComponent("latest", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: latest, withIntermediateDirectories: false)
        try Data().write(to: first.appendingPathComponent("old.txt"))
        try Data().write(to: latest.appendingPathComponent("latest.txt"))
        let browser = LocalFileBrowserViewModel(startingAt: directory)

        browser.navigate(to: first)
        browser.navigate(to: latest)
        try await waitForIdle(browser)

        XCTAssertEqual(browser.currentURL, latest.standardizedFileURL)
        XCTAssertEqual(browser.items.map { $0.url.lastPathComponent }, ["latest.txt"])
        XCTAssertFalse(browser.followsTerminal)

        browser.syncTo(path: first.path)
        XCTAssertEqual(browser.currentURL, latest.standardizedFileURL)
        browser.setFollowTerminal(true)
        try await waitForIdle(browser)

        XCTAssertTrue(browser.followsTerminal)
        XCTAssertEqual(browser.currentURL, first.standardizedFileURL)
        XCTAssertEqual(browser.items.map { $0.url.lastPathComponent }, ["old.txt"])
    }

    @MainActor
    private func waitForIdle(_ browser: LocalFileBrowserViewModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while browser.isLoading || browser.isWorking {
            guard Date() < deadline else {
                XCTFail("The file browser did not finish its operation")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
