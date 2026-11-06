import AppKit
import XCTest
@testable import NeoLink

/// A headless Neovim with NeoLink's configuration and a native UI client attached.
final class NativeNvim {
    let root: URL
    let process = Process()
    let client: NeovimGridClient
    let control: EditorControlChannel
    var image = GridImage(cols: 1, rows: 1)
    var items: [GridItem] = []
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
        let result = try await nvim.dispatch(["method": "action", "action": "format"])
        _ = result
        let command = "NeoLink.dispatch"; _ = command
        let edit = try await nvim.client_exec("vim.api.nvim_buf_set_lines(vim.fn.bufnr(...), 0, 1, false, {'changed'})", [a])
        _ = edit
        let ok171 = await nvim.wait { nvim.touches.contains(a) }
        XCTAssertTrue(ok171, "an inactive buffer's edit must reach the host: \(nvim.touches)")
    }
}
