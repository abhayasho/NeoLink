import AppKit
import SwiftUI
import XCTest
@testable import NeoLink

/// A headless Neovim with NeoLink's configuration and a native UI client attached.
final class NativeNvim {
    let root: URL
    let process = Process()
    let client: NeovimGridClient
    let control: EditorControlChannel
    var image = GridImage(cols: 1, rows: 1)
    var items: [NativeGridItem] = []
    var selections: [(token: UInt64, path: String, screen: [String])] = []
    var leaves: [(path: String, mode: String, popup: Bool, screen: [String])] = []
    var touches: [String] = []
    private(set) var framesSeen = 0

    init(cols: Int = 60, rows: Int = 16) async throws {
        guard let nvim = CommandRunner.executable("nvim") else { throw XCTSkip("Neovim is optional") }
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("neolink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["NEOLINK_STATUS_FILE"] = root.appendingPathComponent("status.json").path
        environment["NEOLINK_CONTROL_SOCKET"] = root.appendingPathComponent("control.sock").path
        environment["XDG_STATE_HOME"] = root.path; environment["XDG_CACHE_HOME"] = root.path; environment["XDG_DATA_HOME"] = root.path
        let configuration = await MainActor.run { NeovimSession.configurationURL }
        process.executableURL = URL(fileURLWithPath: nvim)
        process.arguments = ["--headless", "--noplugin", "-u", configuration.path, "-i", "NONE",
                             "--listen", root.appendingPathComponent("editor.sock").path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        control = EditorControlChannel(path: root.appendingPathComponent("control.sock").path)
        client = NeovimGridClient(socketPath: root.appendingPathComponent("editor.sock").path)
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("editor.sock").path),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("control.sock").path),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("status.json").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await client.attach(cols: cols, rows: rows)
    }

    func stop() {
        client.detach(); control.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }

    var screen: [String] { image.rows.map { $0.map { $0.text.isEmpty ? "" : $0.text }.joined().trimmingCharacters(in: .whitespaces) } }

    /// Applies everything published so far, in order, recording the screen at each control item.
    @discardableResult
    func pump() -> Int {
        let drained = client.mailbox.drain()
        for item in drained {
            items.append(item)
            switch item {
            case .frame(let frame): image.apply(frame); framesSeen += 1
            case .selection(let token, let path): selections.append((token, path, screen))
            case .leave(let path, let mode, let popup, _): leaves.append((path, mode, popup, screen))
            case .touch(let path): touches.append(path)
            case .closed: break
            }
        }
        return drained.count
    }

    func wait(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        pump()
        return condition()
    }

    /// Runs Lua in the editor over an independent API connection (as an LSP edit or plugin would act).
    func client_exec(_ code: String, _ args: [String]) async throws -> MsgPackValue {
        let side = NeovimRPCConnection(path: root.appendingPathComponent("editor.sock").path)
        try side.connect()
        defer { side.close() }
        return try await side.request("nvim_exec_lua", [.string(code), .array(args.map { .string($0) })])
    }

    func dispatch(_ message: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: message)
        let reply = try await control.request(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
}

final class NativeGridEditorTests: XCTestCase {
    private func files(_ names: [String: String]) throws -> (URL, [String: URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeGrid-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var urls: [String: URL] = [:]
        for (name, text) in names {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            urls[name] = url
        }
        return (root, urls)
    }

    func testRedrawEventsReproduceNeovimsOwnScreenAndTheSelectionEchoFollowsTheBufferEnterRedraw() async throws {
        let (root, urls) = try files(["a.txt": "ALPHA first buffer\nsecond line\n", "b.txt": "BRAVO other buffer\nsecond line\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let nvim = try await NativeNvim()
        defer { nvim.stop() }
        let a = urls["a.txt"]!.path, b = urls["b.txt"]!.path
        let ok112 = await nvim.wait { nvim.framesSeen > 0 }
        XCTAssertTrue(ok112)
        // Alternate buffers many times. At each echo, everything applied so far must already show
        // exactly that buffer: no earlier buffer, no half-drawn screen.
        for round in 1...40 {
            let path = round % 2 == 1 ? a : b
            let marker = round % 2 == 1 ? "ALPHA" : "BRAVO"
            let reply = try await nvim.dispatch(["method": "open", "path": path, "activate": true, "selection": round])
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
            let ok121 = await nvim.wait { nvim.selections.contains { $0.token == UInt64(round) } }
            XCTAssertTrue(ok121, "echo \(round)")
            let echo = try XCTUnwrap(nvim.selections.first { $0.token == UInt64(round) })
            XCTAssertEqual(echo.path, path)
            XCTAssertTrue(echo.screen.contains { $0.contains(marker) }, "round \(round): \(echo.screen)")
            XCTAssertFalse(echo.screen.contains { $0.contains(marker == "ALPHA" ? "BRAVO" : "ALPHA") }, "round \(round): wrong buffer at echo")
        }
        // The grid is a faithful copy: its statusline names the displayed file.
        XCTAssertTrue(nvim.screen.contains { $0.contains("b.txt") }, "\(nvim.screen)")
    }

    func testLeaveNoticeDescribesTheScreenBeingLeftAndInsertModeNeverCaches() async throws {
        let (root, urls) = try files(["a.txt": "ALPHA\n", "b.txt": "BRAVO\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let nvim = try await NativeNvim()
        defer { nvim.stop() }
        _ = try await nvim.dispatch(["method": "open", "path": urls["a.txt"]!.path, "activate": true, "selection": 1])
        let ok138 = await nvim.wait { nvim.selections.count == 1 }
        XCTAssertTrue(ok138)
        _ = try await nvim.dispatch(["method": "open", "path": urls["b.txt"]!.path, "activate": true, "selection": 2])
        let ok141 = await nvim.wait { nvim.selections.count == 2 }
        XCTAssertTrue(ok141)
        let leave = try XCTUnwrap(nvim.leaves.first { $0.path == urls["a.txt"]!.path })
        XCTAssertTrue(leave.mode.hasPrefix("i"), "NeoLink opens buffers in insert mode")
        XCTAssertFalse(leave.popup)
        XCTAssertTrue(leave.screen.contains { $0.contains("ALPHA") }, "At the leave notice the client already shows the buffer being left: \(leave.screen)")
        XCTAssertFalse(leave.screen.contains { $0.contains("BRAVO") })
        // An explicit leave (switching to a shell tab) records the screen without opening anything.
        _ = try await nvim.dispatch(["method": "leave"])
        let ok150 = await nvim.wait { nvim.leaves.contains { $0.path == urls["b.txt"]!.path } }
        XCTAssertTrue(ok150)
    }

    func testBackgroundChangesAndSavesNotifyTouchSoACachedImageCannotGoStale() async throws {
        let (root, urls) = try files(["a.txt": "ALPHA\n", "b.txt": "BRAVO\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let nvim = try await NativeNvim()
        defer { nvim.stop() }
        let a = urls["a.txt"]!.path
        _ = try await nvim.dispatch(["method": "open", "path": a, "activate": true, "selection": 1])
        _ = try await nvim.dispatch(["method": "open", "path": urls["b.txt"]!.path, "activate": true, "selection": 2])
        let ok162 = await nvim.wait { nvim.selections.count == 2 }
        XCTAssertTrue(ok162)
        nvim.touches.removeAll()
        // Edit the inactive buffer behind the editor's back (an LSP workspace edit does exactly this).
        _ = try await nvim.client_exec("vim.api.nvim_buf_set_lines(vim.fn.bufnr(...), 0, 1, false, {'changed'})", [a])
        let ok171 = await nvim.wait { nvim.touches.contains(a) }
        XCTAssertTrue(ok171, "an inactive buffer's edit must reach the host: \(nvim.touches)")
    }

    @MainActor
    func testNativeSessionSwitchesBuffersEditsSavesAndReusesValidatedImages() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        _ = NSApplication.shared
        setenv("NEOLINK_NATIVE_GRID", "1", 1)
        defer { unsetenv("NEOLINK_NATIVE_GRID") }
        let (root, urls) = try files(["a.txt": "ALPHA line one\nsecond\n", "b.txt": "BRAVO line one\nsecond\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = TabsController()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabbedTerminalView(controller: controller))
        defer { controller.codeSession.shutdown(); controller.tabs.compactMap(\.terminal).forEach { $0.state.close() }; window.close() }
        window.makeKeyAndOrderFront(nil)
        controller.openFile(urls["a.txt"]!)
        let first = try XCTUnwrap(controller.selectedTabID)
        try await settleEditor(controller)
        controller.openFile(urls["b.txt"]!)
        let second = try XCTUnwrap(controller.selectedTabID)
        try await settleEditor(controller)
        let session = controller.codeSession
        XCTAssertTrue(session.usesNativeGrid, "native client active: \(session.nativeFallbackReason ?? "no fallback")")
        let terminal = try XCTUnwrap(session.terminal)
        XCTAssertFalse(terminal.process.running, "No PTY process exists in native mode")
        func screen() -> String { (0..<terminal.getTerminal().rows).map { terminal.getTerminal().externalGridRowText($0) }.joined(separator: "\n") }
        for round in 0..<14 {
            let (target, marker, other) = round % 2 == 0 ? (first, "ALPHA", "BRAVO") : (second, "BRAVO", "ALPHA")
            controller.selectedTabID = target
            try await settleEditor(controller)
            XCTAssertEqual(session.parsedSelection, session.selectionToken)
            XCTAssertTrue(screen().contains(marker), "round \(round)\n\(screen())")
            XCTAssertFalse(screen().contains(other), "round \(round) shows the other buffer\n\(screen())")
        }
        let presenter = try XCTUnwrap(session.nativeGrid)
        XCTAssertGreaterThan(presenter.speculations, 0, "switch-backs reuse validated images: \(presenter.speculationRejections)")
        XCTAssertGreaterThan(presenter.geometryReuses, 0, "after the first round trip, retained rows are re-installed rather than rewritten")
        XCTAssertGreaterThan(presenter.confirmedSpeculations, 0)
        XCTAssertEqual(presenter.speculationCorrections, 0, "a validated image is exactly what Neovim then draws: confirmation rewrote no row")
        // After the confirmation the terminal equals Neovim's own screen, whichever path showed it.
        try await Task.sleep(nanoseconds: 200_000_000)
        presenter.drain()
        XCTAssertEqual(presenter.phase, .live)
        let mirrorText = presenter.mirror.rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        let shownText = (0..<terminal.getTerminal().rows).map { terminal.getTerminal().externalGridRowText($0).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(shownText, mirrorText)
        // Typing reaches the active buffer and only that buffer; saving writes it.
        controller.selectedTabID = first
        try await settleEditor(controller)
        terminal.send(txt: "typed<in>")
        try await settleEditor(controller) { controller.selectedTab?.document?.isModified == true && screen().contains("typed<in>") }
        let saved = await session.save(urls["a.txt"]!)
        XCTAssertTrue(saved)
        XCTAssertTrue(try String(contentsOf: urls["a.txt"]!).hasPrefix("typed<in>ALPHA"))
        XCTAssertEqual(try String(contentsOf: urls["b.txt"]!), "BRAVO line one\nsecond\n")
        // A change on disk invalidates the cached image: returning must show the new contents.
        controller.selectedTabID = second
        try await settleEditor(controller)
        try Data("BRAVO rewritten by an agent\n".utf8).write(to: urls["b.txt"]!)
        controller.selectedTabID = first
        try await settleEditor(controller)
        controller.selectedTabID = second
        try await settleEditor(controller) { controller.selectedTabID == second && session.requestedPath == nil && screen().contains("rewritten by an agent") }
        XCTAssertTrue(screen().contains("rewritten by an agent"), screen())
        XCTAssertNil(session.error)
    }

    @MainActor
    func testCachedImageStaysExactAfterTheCursorMovesAndTheViewScrolls() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        _ = NSApplication.shared
        setenv("NEOLINK_NATIVE_GRID", "1", 1)
        defer { unsetenv("NEOLINK_NATIVE_GRID") }
        let long = (1...300).map { "line \($0) of a long file, with some text to scroll through" }.joined(separator: "\n") + "\n"
        let (root, urls) = try files(["long.txt": long, "short.txt": "SHORT\n", "other.txt": "OTHER\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = TabsController()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabbedTerminalView(controller: controller))
        defer { controller.codeSession.shutdown(); controller.tabs.compactMap(\.terminal).forEach { $0.state.close() }; window.close() }
        window.makeKeyAndOrderFront(nil)
        controller.openFile(urls["long.txt"]!); let long1 = try XCTUnwrap(controller.selectedTabID); try await settleEditor(controller)
        controller.openFile(urls["short.txt"]!); let short1 = try XCTUnwrap(controller.selectedTabID); try await settleEditor(controller)
        controller.openFile(urls["other.txt"]!); let other = try XCTUnwrap(controller.selectedTabID); try await settleEditor(controller)
        let session = controller.codeSession, presenter = try XCTUnwrap(session.nativeGrid), terminal = try XCTUnwrap(session.terminal)
        func screen() -> String { (0..<terminal.getTerminal().rows).map { terminal.getTerminal().externalGridRowText($0) }.joined(separator: "\n") }
        // Round trips that leave the long file at different cursor positions and scroll offsets.
        for step in ["<PageDown><PageDown>", "<Down><Down><Down><Right><Right>", "<PageUp>", "<C-End>", "<Home><Up><Up>"] {
            controller.selectedTabID = long1; try await settleEditor(controller)
            presenter.send(keys: step)
            try await Task.sleep(nanoseconds: 150_000_000)
            for target in [short1, long1, other, long1] {
                controller.selectedTabID = target
                try await settleEditor(controller)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            XCTAssertTrue(screen().contains("of a long file"), "step \(step)")
        }
        XCTAssertGreaterThan(presenter.confirmedSpeculations, 5, "\(presenter.speculationRejections)")
        XCTAssertEqual(presenter.speculationCorrections, 0, "cached images were exact after \(presenter.confirmedSpeculations) confirmations; rejected: \(presenter.speculationRejections)")
    }

    @MainActor
    func testResizeFollowsTheWindowAndNeverDrawsAStaleSizedGrid() async throws {
        guard CommandRunner.executable("nvim") != nil else { throw XCTSkip("Neovim is optional") }
        _ = NSApplication.shared
        setenv("NEOLINK_NATIVE_GRID", "1", 1)
        defer { unsetenv("NEOLINK_NATIVE_GRID") }
        let text = (1...80).map { "row \($0) — 界 ünïcode and a reasonably long line of text to fill the width" }.joined(separator: "\n") + "\n"
        let (root, urls) = try files(["a.txt": text, "b.txt": "BRAVO\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = TabsController()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabbedTerminalView(controller: controller))
        defer { controller.codeSession.shutdown(); controller.tabs.compactMap(\.terminal).forEach { $0.state.close() }; window.close() }
        window.makeKeyAndOrderFront(nil)
        controller.openFile(urls["a.txt"]!); let first = try XCTUnwrap(controller.selectedTabID); try await settleEditor(controller)
        controller.openFile(urls["b.txt"]!); let second = try XCTUnwrap(controller.selectedTabID); try await settleEditor(controller)
        let session = controller.codeSession, presenter = try XCTUnwrap(session.nativeGrid), terminal = try XCTUnwrap(session.terminal)
        func agreed() -> Bool {
            let size = terminal.getTerminal()
            return presenter.mirror.cols == size.cols && presenter.mirror.rowCount == size.rows && presenter.requestedSize == (size.cols, size.rows)
        }
        func screen() -> [String] { (0..<terminal.getTerminal().rows).map { terminal.getTerminal().externalGridRowText($0) } }
        XCTAssertTrue(agreed())
        controller.selectedTabID = first; try await settleEditor(controller)
        XCTAssertTrue(screen().contains { $0.contains("row 1 ") })
        controller.selectedTabID = second; try await settleEditor(controller)   // leaves an image of `a.txt` behind
        let before = (terminal.getTerminal().cols, terminal.getTerminal().rows)
        for size in [NSSize(width: 1180, height: 760), NSSize(width: 700, height: 420), NSSize(width: 1000, height: 640)] {
            window.setContentSize(size)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, !(agreed() && presenter.phase == .live && presenter.framesApplied > 0) { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 200_000_000); presenter.drain()
            XCTAssertTrue(agreed(), "terminal \(terminal.getTerminal().cols)x\(terminal.getTerminal().rows) mirror \(presenter.mirror.cols)x\(presenter.mirror.rowCount)")
            XCTAssertTrue(screen().contains { $0.contains("BRAVO") }, "content survives a resize to \(size)")
            XCTAssertNil(session.error)
        }
        XCTAssertNotEqual(before.0, terminal.getTerminal().cols, "the window size changed the grid")
        // Images from before the resizes have the wrong size and are gone; a switch back waits for Neovim.
        XCTAssertTrue(presenter.cache.entries.values.allSatisfy { $0.image.cols == terminal.getTerminal().cols && $0.lines.allSatisfy { $0.count == terminal.getTerminal().cols } },
                      "no cached image or retained row of another size survives a resize")
        controller.selectedTabID = first
        try await settleEditor(controller)
        XCTAssertTrue(screen().contains { $0.contains("row 1 ") })
        XCTAssertTrue(agreed())
    }

    @MainActor
    private func settleEditor(_ controller: TabsController, extra: () -> Bool = { true }) async throws {
        let deadline = Date().addingTimeInterval(8)
        func ready() -> Bool {
            controller.codeSession.requestedPath == nil && controller.codeSession.terminal?.isHidden == false
                && controller.tabs.compactMap(\.document).allSatisfy { !$0.isLoading } && controller.codeSession.isReady
                && controller.codeSession.nativeGrid?.phase != .some(.speculative(token: controller.codeSession.selectionToken)) && extra()
        }
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(ready(), "Editor did not settle")
        try await Task.sleep(nanoseconds: 40_000_000)
    }
}
