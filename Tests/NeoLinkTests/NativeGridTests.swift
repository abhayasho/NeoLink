import AppKit
import Metal
import XCTest
import SwiftTerm
@testable import NeoLink

// MARK: Helpers

private func event(_ name: String, _ calls: MsgPackValue...) -> MsgPackValue {
    .array([.string(name)] + calls)
}
private func gridLine(row: Int, column: Int, cells: [[MsgPackValue]]) -> MsgPackValue {
    .array([.int(1), .int(Int64(row)), .int(Int64(column)), .array(cells.map { .array($0) }), .bool(false)])
}
private func cell(_ text: String, _ hl: Int? = nil, _ repeats: Int? = nil) -> [MsgPackValue] {
    var fields: [MsgPackValue] = [.string(text)]
    if let hl { fields.append(.int(Int64(hl))) }
    if let repeats { if hl == nil { fields.append(.null) }; fields.append(.int(Int64(repeats))) }
    return fields
}
private func map(_ pairs: [(String, MsgPackValue)]) -> MsgPackValue { .map(pairs.map { MsgPackPair(.string($0.0), $0.1) }) }

final class NativeGridProtocolTests: XCTestCase {
    func testMsgPackRoundTripsEveryTypeAndDecodesByteByByte() throws {
        let value: MsgPackValue = .array([
            .null, .bool(true), .bool(false), .int(0), .int(127), .int(128), .int(255), .int(256), .int(65_535), .int(65_536),
            .int(4_294_967_295), .int(4_294_967_296), .int(-1), .int(-32), .int(-33), .int(-128), .int(-129), .int(-32_768),
            .int(-32_769), .int(-2_147_483_648), .int(-2_147_483_649), .uint(UInt64.max), .double(1.5), .double(-0.25),
            .string(""), .string("héllo 界 👋"), .string(String(repeating: "x", count: 40)), .string(String(repeating: "y", count: 300)),
            .binary([1, 2, 3]), .binary(Array(repeating: 7, count: 300)),
            .array((0..<20).map { .int(Int64($0)) }),
            map([("a", .int(1)), ("b", .array([.string("c")]))]),
            .map((0..<20).map { MsgPackPair(.int(Int64($0)), .bool($0 % 2 == 0)) }),
            .ext(1, [9]), .ext(5, [1, 2, 3]),
        ])
        let bytes = value.encoded
        var whole = MsgPackStream()
        try whole.append(bytes)
        XCTAssertEqual(try whole.next(), value)
        XCTAssertNil(try whole.next())
        var chunked = MsgPackStream()
        var decoded: [MsgPackValue] = []
        for byte in bytes + bytes {
            try chunked.append([byte])
            while let next = try chunked.next() { decoded.append(next) }
        }
        XCTAssertEqual(decoded, [value, value], "Two messages split at every byte boundary decode identically")
        XCTAssertEqual(chunked.bufferedByteCount, 0)
    }

    func testMsgPackRejectsMalformedAndOversizedInput() throws {
        var unsupported = MsgPackStream()
        try unsupported.append([0xc1])
        XCTAssertThrowsError(try unsupported.next())
        var deep = MsgPackStream()
        try deep.append(Array(repeating: 0x91, count: 100) + [0xc0])
        XCTAssertThrowsError(try deep.next(), "Nesting is bounded")
        var lie = MsgPackStream()
        try lie.append([0xdd, 0xff, 0xff, 0xff, 0xff])   // 4 billion elements
        XCTAssertThrowsError(try lie.next(), "A claimed length beyond the message limit is refused")
        var claim = MsgPackStream()
        try claim.append([0xdc, 0xff, 0xff, 1, 2])   // 65 535 elements but two bytes follow
        XCTAssertNil(try claim.next(), "An implausible count waits for more bytes instead of allocating")
    }

    func testLineGridAppliesRepeatsOmittedHighlightsAndWideCells() {
        let model = NeovimGridModel(cols: 8, rows: 3)
        model.apply(redraw: [
            event("grid_resize", .array([.int(1), .int(8), .int(3)])),
            event("hl_attr_define", .array([.int(7), map([("foreground", .int(0xff0000)), ("bold", .bool(true))]), .map([]), .array([])])),
            event("grid_line", gridLine(row: 0, column: 0, cells: [cell("a", 7), cell("b"), cell("c", 0, 2), cell("界", 7), cell("")])),
            event("grid_cursor_goto", .array([.int(1), .int(1), .int(2)])),
        ])
        let frame = model.takeFrame()!
        XCTAssertTrue(frame.resized)
        let row = frame.rowUpdates[0]!
        XCTAssertEqual(row.map(\.text), ["a", "b", "c", "c", "界", "", " ", " "])
        XCTAssertEqual(row.map(\.hl), [7, 7, 0, 0, 7, 7, 0, 0], "An omitted highlight repeats the previous cell's")
        XCTAssertEqual(frame.cursorRow, 1); XCTAssertEqual(frame.cursorColumn, 2)
        XCTAssertEqual(frame.highlights[7]?.foreground, 0xff0000)
        XCTAssertEqual(frame.highlights[7]?.bold, true)
        XCTAssertNil(model.takeFrame(), "Nothing changed since the last flush")
    }

    func testEmitsOnlyRowsWhoseContentActuallyChanged() {
        let model = NeovimGridModel(cols: 4, rows: 3)
        model.apply(redraw: [event("grid_resize", .array([.int(1), .int(4), .int(3)])),
                             event("grid_line", gridLine(row: 0, column: 0, cells: [cell("x", 0, 4)]))])
        _ = model.takeFrame()
        model.apply(redraw: [event("grid_line", gridLine(row: 0, column: 0, cells: [cell("x", 0, 4)])),   // identical
                             event("grid_line", gridLine(row: 2, column: 1, cells: [cell("y", 0)]))])
        let frame = model.takeFrame()!
        XCTAssertEqual(Set(frame.rowUpdates.keys), [2])
    }

    func testScrollMovesRowsInBothDirectionsWithinTheRegionOnly() {
        let model = NeovimGridModel(cols: 3, rows: 5)
        var lines: [MsgPackValue] = [event("grid_resize", .array([.int(1), .int(3), .int(5)]))]
        for row in 0..<5 { lines.append(event("grid_line", gridLine(row: row, column: 0, cells: [cell(String(row), 0, 3)]))) }
        model.apply(redraw: lines)
        _ = model.takeFrame()
        func text() -> [String] { model.image.rows.map { $0[0].text } }
        XCTAssertEqual(text(), ["0", "1", "2", "3", "4"])
        // Rows 1..<4 scroll up by one: row 1 receives row 2's content, row 3 keeps stale content for the redraw to replace.
        model.apply(redraw: [event("grid_scroll", .array([.int(1), .int(1), .int(4), .int(0), .int(3), .int(1), .int(0)]))])
        XCTAssertEqual(text(), ["0", "2", "3", "3", "4"])
        model.apply(redraw: [event("grid_scroll", .array([.int(1), .int(1), .int(4), .int(0), .int(3), .int(-1), .int(0)]))])
        XCTAssertEqual(text(), ["0", "2", "2", "3", "4"])
        let frame = model.takeFrame()!
        XCTAssertEqual(frame.scrolls, [GridScroll(top: 1, bottom: 4, lines: 1), GridScroll(top: 1, bottom: 4, lines: -1)])
    }

    func testPartialWidthScrollCopiesOnlyItsColumns() {
        let model = NeovimGridModel(cols: 4, rows: 3)
        model.apply(redraw: [event("grid_resize", .array([.int(1), .int(4), .int(3)])),
                             event("grid_line", gridLine(row: 0, column: 0, cells: [cell("a"), cell("b"), cell("c"), cell("d")])),
                             event("grid_line", gridLine(row: 1, column: 0, cells: [cell("1"), cell("2"), cell("3"), cell("4")]))])
        _ = model.takeFrame()
        model.apply(redraw: [event("grid_scroll", .array([.int(1), .int(0), .int(2), .int(2), .int(4), .int(1), .int(0)]))])
        XCTAssertEqual(model.image.rows[0].map(\.text), ["a", "b", "3", "4"])
        XCTAssertTrue(model.takeFrame()!.scrolls.isEmpty, "Only full-width scrolls are replayed as terminal region scrolls")
    }

    func testHighlightRedefinitionAndDefaultColorsAdvanceTheStyleEpoch() {
        let model = NeovimGridModel(cols: 2, rows: 2)
        model.apply(redraw: [event("hl_attr_define", .array([.int(3), map([("foreground", .int(1))]), .map([]), .array([])]))])
        let first = model.takeFrame()!.styleEpoch
        model.apply(redraw: [event("hl_attr_define", .array([.int(3), map([("foreground", .int(1))]), .map([]), .array([])]))])
        XCTAssertEqual(model.takeFrame()?.styleEpoch ?? first, first, "Re-sending an identical definition is not a change")
        model.apply(redraw: [event("hl_attr_define", .array([.int(3), map([("foreground", .int(2))]), .map([]), .array([])]))])
        let second = model.takeFrame()!.styleEpoch
        XCTAssertGreaterThan(second, first)
        model.apply(redraw: [event("default_colors_set", .array([.int(0x101010), .int(0x202020), .int(0x303030), .int(-1), .int(-1)]))])
        let third = model.takeFrame()!
        XCTAssertGreaterThan(third.styleEpoch, second)
        XCTAssertEqual(third.defaults?.background, 0x202020)
    }

    func testMergedFramesEqualApplyingEachInOrder() {
        let model = NeovimGridModel(cols: 4, rows: 4)
        var one = GridImage(cols: 4, rows: 4), merged = GridImage(cols: 4, rows: 4)
        var frames: [GridFrame] = []
        let batches: [[MsgPackValue]] = [
            [event("grid_resize", .array([.int(1), .int(4), .int(4)])), event("grid_line", gridLine(row: 0, column: 0, cells: [cell("a", 0, 4)]))],
            [event("grid_line", gridLine(row: 1, column: 0, cells: [cell("b", 0, 4)])), event("grid_cursor_goto", .array([.int(1), .int(1), .int(1)]))],
            [event("grid_scroll", .array([.int(1), .int(0), .int(4), .int(0), .int(4), .int(1), .int(0)])),
             event("grid_line", gridLine(row: 3, column: 0, cells: [cell("z", 0, 4)]))],
            [event("grid_line", gridLine(row: 0, column: 0, cells: [cell("q", 0, 4)]))],
        ]
        for batch in batches { model.apply(redraw: batch); if let frame = model.takeFrame() { frames.append(frame) } }
        for frame in frames { one.apply(frame) }
        merged.apply(frames.dropFirst().reduce(frames[0]) { $0.merging($1) })
        XCTAssertEqual(one, merged)
        XCTAssertEqual(merged, model.image)
    }

    func testMailboxMergesAdjacentFramesButKeepsOrderedControlItemsBetweenThem() {
        let mailbox = GridMailbox()
        func frame(_ text: String) -> GridFrame {
            var frame = GridFrame(cols: 1, rowCount: 1)
            frame.rowUpdates[0] = [GridCell(text: text, hl: 0)]
            return frame
        }
        XCTAssertTrue(mailbox.push(.frame(frame("a"))))
        XCTAssertFalse(mailbox.push(.frame(frame("b"))))
        mailbox.push(.selection(token: 4, path: "/x"))
        mailbox.push(.frame(frame("c")))
        let items = mailbox.drain()
        XCTAssertEqual(items.count, 3)
        guard case .frame(let first) = items[0], case .selection(let token, _) = items[1], case .frame(let last) = items[2] else { return XCTFail("order") }
        XCTAssertEqual(first.rowUpdates[0]?.first?.text, "b", "Frames before the echo coalesce, never across it")
        XCTAssertEqual(token, 4)
        XCTAssertEqual(last.rowUpdates[0]?.first?.text, "c")
        XCTAssertTrue(mailbox.isEmpty)
    }

    func testSnapshotCacheShowsOnlyWhileEveryConditionStillHolds() {
        var cache = GridSnapshotCache()
        let signature = FileSignature(size: 10, seconds: 5, nanoseconds: 1, inode: 3)
        let entry = GridSnapshotCache.Entry(image: GridImage(cols: 10, rows: 4), styleEpoch: 2, diagnosticsEnabled: true, signature: signature)
        cache.store(entry, for: "/a")
        func lookup(cols: Int = 10, rows: Int = 4, epoch: Int = 2, diagnostics: Bool = true, signature: FileSignature? = signature) -> Bool {
            cache.validEntry(for: "/a", cols: cols, rows: rows, styleEpoch: epoch, diagnosticsEnabled: diagnostics, signature: signature) != nil
        }
        XCTAssertTrue(lookup())
        XCTAssertFalse(lookup(cols: 11), "window size")
        XCTAssertFalse(lookup(rows: 5), "window size")
        XCTAssertFalse(lookup(epoch: 3), "colour scheme / highlight change")
        XCTAssertFalse(lookup(diagnostics: false), "diagnostics visibility")
        XCTAssertFalse(lookup(signature: FileSignature(size: 11, seconds: 5, nanoseconds: 1, inode: 3)), "external change or save")
        XCTAssertFalse(lookup(signature: nil), "file removed")
        cache.invalidate(path: "/a")
        XCTAssertFalse(lookup(), "a touched buffer waits for Neovim's flush")
        cache.store(entry, for: "/a"); cache.store(entry, for: "/b")
        cache.invalidate(path: "")
        XCTAssertTrue(cache.entries.isEmpty, "layout/option/colour changes clear every image")
    }

    func testSnapshotCacheIsBoundedAndEvictsLeastRecentlyStored() {
        var cache = GridSnapshotCache()
        let entry = GridSnapshotCache.Entry(image: GridImage(cols: 2, rows: 2), styleEpoch: 0, diagnosticsEnabled: true, signature: nil)
        for index in 0..<(GridSnapshotCache.limit + 5) { cache.store(entry, for: "/file-\(index)") }
        XCTAssertEqual(cache.entries.count, GridSnapshotCache.limit)
        XCTAssertNil(cache.entries["/file-0"])
        XCTAssertNotNil(cache.entries["/file-\(GridSnapshotCache.limit + 4)"])
    }

    func testKeyEncodingTranslatesSpecialControlAndTextKeys() {
        func encode(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String? = nil) -> String? {
            NeovimKeyEncoder.encode(keyCode: code, modifiers: flags, charactersIgnoringModifiers: chars)
        }
        XCTAssertEqual(encode(36), "<CR>")
        XCTAssertEqual(encode(53), "<Esc>")
        XCTAssertEqual(encode(51), "<BS>")
        XCTAssertEqual(encode(48), "<Tab>")
        XCTAssertEqual(encode(48, .shift), "<S-Tab>")
        XCTAssertEqual(encode(126), "<Up>")
        XCTAssertEqual(encode(123, .shift), "<S-Left>")
        XCTAssertEqual(encode(124, [.control, .option]), "<C-M-Right>")
        XCTAssertEqual(encode(122), "<F1>")
        XCTAssertEqual(encode(1, .control, "s"), "<C-s>")
        XCTAssertEqual(encode(0, [.control, .shift], "a"), "<C-a>", "Letters already carry their case in the key name")
        XCTAssertEqual(encode(0, .option, "a"), nil, "Option composes characters; the input system decides")
        XCTAssertEqual(encode(1, .command, "s"), nil, "Command is for menu equivalents")
        XCTAssertNil(encode(0, [], "a"), "Plain text goes through the input system")
        XCTAssertEqual(NeovimKeyEncoder.escape(text: "a<b>"), "a<lt>b>")
        XCTAssertEqual(NeovimKeyEncoder.escape(text: "界 👋"), "界 👋")
        XCTAssertEqual(NeovimKeyEncoder.escape(text: "\r"), "<CR>")
        XCTAssertEqual(NeovimKeyEncoder.escape(text: "\u{1b}"), "<Esc>")
        XCTAssertEqual(NeovimKeyEncoder.escape(text: "\u{1b}[A"), "", "Terminal escape sequences are not Neovim input")
        XCTAssertEqual(NeovimKeyEncoder.mouseModifiers([.shift, .control]), "SC")
    }
}

// MARK: Rendering parity with the terminal path

final class NativeGridRenderingTests: XCTestCase {
    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        window.orderFrontRegardless()
        return window
    }

    @MainActor
    private func capture(_ view: TerminalView) throws -> CGImage {
        let done = expectation(description: "frame")
        var image: CGImage?
        view.metalFrameCapture = { image = $0; done.fulfill() }
        view.drawMetalFrameNow()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(image)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    @MainActor
    func testNativeGridTextIsPixelIdenticalToTheTerminalPathForTheSameContent() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        // The editor view attaches its own display-link presentation to any window; this test drives
        // frames directly, so keep the shared GPU preference from handing it to that owner.
        let gpuPreference = TerminalRenderingPreferences.shared.useGPU
        TerminalRenderingPreferences.shared.setUseGPU(false)
        defer { TerminalView.allowsMetalFrameCapture = false; TerminalRenderingPreferences.shared.setUseGPU(gpuPreference) }
        let reference = TerminalView(frame: .zero)
        let native = CodeTerminalView(frame: .zero)
        let windows = [window(reference), window(native)]
        defer { windows.forEach { $0.close() } }
        for view in [reference, native] {
            view.nativeForegroundColor = NSColor(hex: 0xd8d8d8); view.nativeBackgroundColor = NSColor(hex: 0x181818)
            try view.setUseMetal(true)
        }
        let cols = native.getTerminal().cols, rows = native.getTerminal().rows
        XCTAssertEqual(cols, reference.getTerminal().cols)
        XCTAssertEqual(rows, reference.getTerminal().rows)

        // The same screen two ways: escape sequences through the VT parser, and Neovim grid events.
        let model = NeovimGridModel(cols: cols, rows: rows)
        var events: [MsgPackValue] = [
            event("grid_resize", .array([.int(1), .int(Int64(cols)), .int(Int64(rows))])),
            event("default_colors_set", .array([.int(0xd8d8d8), .int(0x181818), .int(-1), .int(-1), .int(-1)])),
        ]
        func define(_ id: Int, _ attributes: [(String, MsgPackValue)]) {
            events.append(event("hl_attr_define", .array([.int(Int64(id)), map(attributes), .map([]), .array([])])))
        }
        define(1, [("foreground", .int(0xcc9595))])
        define(2, [("bold", .bool(true)), ("foreground", .int(0xa8ccdf))])
        define(3, [("italic", .bool(true)), ("foreground", .int(0xd6b3d2))])
        define(4, [("background", .int(0x343434))])
        define(5, [("reverse", .bool(true))])
        define(6, [("underline", .bool(true)), ("foreground", .int(0xd6d6a4))])
        define(7, [("strikethrough", .bool(true))])
        define(8, [("bold", .bool(true)), ("italic", .bool(true)), ("foreground", .int(0xa4b29b)), ("background", .int(0x283128))])
        func line(_ row: Int, _ cells: [[MsgPackValue]]) { events.append(event("grid_line", gridLine(row: row, column: 0, cells: cells))) }
        /// One grid cell per grapheme, as Neovim sends them.
        func run(_ text: String, _ hl: Int) -> [[MsgPackValue]] { text.map { cell(String($0), hl) } }
        func pad(_ used: Int) -> [[MsgPackValue]] { [cell(" ", 0, cols - used)] }
        line(0, run("plain text with <>{}[] symbols", 0) + pad(30))
        line(1, run("red ", 1) + run("bold ", 2) + run("italic ", 3) + run("shaded ", 4) + run("reverse ", 5) + run("under ", 6) + run("strike", 7) + pad(38))
        line(2, [cell("界", 0), cell(""), cell("面", 1), cell(""), cell("👋", 0), cell(""), cell("e\u{301}", 3), cell("x", 8)] + pad(9))
        line(3, run("gf", 0) + run("i", 2) + run("fi", 0) + pad(5))
        events.append(event("grid_cursor_goto", .array([.int(1), .int(2), .int(3)])))
        events.append(event("busy_start"))
        model.apply(redraw: events)
        let frame = try XCTUnwrap(model.takeFrame())

        // Reference via escape sequences (colours as true colour, default pair unchanged).
        func sgr(_ parts: String) -> String { "\u{1b}[\(parts)m" }
        let reset = sgr("0")
        var text = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[H"
        text += "plain text with <>{}[] symbols\r\n"
        text += sgr("38;2;204;149;149") + "red " + reset + sgr("1;38;2;168;204;223") + "bold " + reset + sgr("3;38;2;214;179;210") + "italic " + reset
        text += sgr("48;2;52;52;52") + "shaded " + reset + sgr("7") + "reverse " + reset + sgr("4;38;2;214;214;164") + "under " + reset + sgr("9") + "strike" + reset + "\r\n"
        text += "界" + sgr("38;2;204;149;149") + "面" + reset + "👋" + sgr("3;38;2;214;179;210") + "e\u{301}" + reset
        text += sgr("1;3;38;2;164;178;155;48;2;40;49;40") + "x" + reset + "\r\n"
        text += "gf" + sgr("1;38;2;168;204;223") + "i" + reset + "fi"
        reference.feed(text: text)

        let presenter = NativeGridPresenter(client: NeovimGridClient(socketPath: "/nonexistent"))
        presenter.prepareTerminal(native)
        presenter.client.mailbox.push(.frame(frame))
        presenter.drain()
        XCTAssertGreaterThan(presenter.rowsWritten, 0)

        XCTAssertTrue(reference.isUsingMetalRenderer && native.isUsingMetalRenderer, "metal \(reference.frame) \(native.frame)")
        let expected = try capture(reference)
        let actual = try capture(native)
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        let a = pixels(actual), b = pixels(expected)
        let differing = zip(a, b).filter { $0 != $1 }.count
        if differing > 0, let dir = ProcessInfo.processInfo.environment["NEOLINK_TEST_ARTIFACTS"] {
            for (name, image) in [("native", actual), ("terminal", expected)] {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
            var rowsDiff = Set<Int>(), colsDiff = Set<Int>()
            for index in 0..<a.count where a[index] != b[index] { let pixel = index / 4; rowsDiff.insert(pixel / actual.width); colsDiff.insert(pixel % actual.width) }
            var cells = Set<String>()
            for index in 0..<a.count where a[index] != b[index] { let pixel = index / 4; cells.insert("(\(pixel % actual.width / 16),\(pixel / actual.width / 32))") }
            print("DIFFCELLS \(cells.sorted())")
            print("DIFF rows \(rowsDiff.min() ?? -1)...\(rowsDiff.max() ?? -1) cols \(colsDiff.min() ?? -1)...\(colsDiff.max() ?? -1) cell \(native.cellSizeInPixels(source: native.getTerminal()) ?? (0, 0))")
        }
        XCTAssertEqual(differing, 0, "\(differing) of \(a.count) bytes differ between the native grid and the terminal path")
        // Bold text is only bright where the terminal path draws it (guard against a vacuous comparison).
        XCTAssertGreaterThan(Set(a.chunked(by: 4)).count, 8)
    }

    /// Renders each step through the native presenter and through the VT parser and requires equal pixels.
    @MainActor
    private func assertParity(steps: [(events: [MsgPackValue], terminal: String)], file: StaticString = #filePath, line: UInt = #line) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        let gpuPreference = TerminalRenderingPreferences.shared.useGPU
        TerminalRenderingPreferences.shared.setUseGPU(false)
        defer { TerminalView.allowsMetalFrameCapture = false; TerminalRenderingPreferences.shared.setUseGPU(gpuPreference) }
        let reference = TerminalView(frame: .zero)
        let native = CodeTerminalView(frame: .zero)
        let windows = [window(reference), window(native)]
        defer { windows.forEach { $0.close() } }
        for view in [reference, native] {
            view.nativeForegroundColor = NSColor(hex: 0xd8d8d8); view.nativeBackgroundColor = NSColor(hex: 0x181818)
            try view.setUseMetal(true)
        }
        let cols = native.getTerminal().cols, rows = native.getTerminal().rows
        let model = NeovimGridModel(cols: cols, rows: rows)
        let modes: [MsgPackValue] = [
            map([("name", .string("normal")), ("cursor_shape", .string("block"))]),
            map([("name", .string("insert")), ("cursor_shape", .string("vertical")), ("cell_percentage", .int(25))]),
            map([("name", .string("replace")), ("cursor_shape", .string("horizontal")), ("cell_percentage", .int(20))]),
        ]
        model.apply(redraw: [event("grid_resize", .array([.int(1), .int(Int64(cols)), .int(Int64(rows))])),
                             event("default_colors_set", .array([.int(0xd8d8d8), .int(0x181818), .int(-1), .int(-1), .int(-1)])),
                             event("mode_info_set", .array([.bool(true), .array(modes)]))])
        reference.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H")
        let presenter = NativeGridPresenter(client: NeovimGridClient(socketPath: "/nonexistent"))
        presenter.prepareTerminal(native)
        for (index, step) in steps.enumerated() {
            model.apply(redraw: step.events)
            if let frame = model.takeFrame() { presenter.client.mailbox.push(.frame(frame)); presenter.drain() }
            reference.feed(text: step.terminal)
            let expected = try capture(reference), actual = try capture(native)
            let differing = zip(pixels(actual), pixels(expected)).filter { $0 != $1 }.count
            XCTAssertEqual(differing, 0, "step \(index): \(differing) bytes differ", file: file, line: line)
        }
    }

    private func rowEvents(_ rows: [(Int, String)], cols: Int, hl: Int = 0) -> [MsgPackValue] {
        rows.map { row, text in
            let cells = text.map { cell(String($0), hl) } + [cell(" ", hl, max(1, cols - text.count))]
            return event("grid_line", gridLine(row: row, column: 0, cells: cells))
        }
    }

    @MainActor
    func testRegionScrollAndRewrittenRowsMatchTheTerminalPathAcrossScrollsAndCursorShapes() throws {
        let cols = 40
        let rows = 9
        var steps: [(events: [MsgPackValue], terminal: String)] = []
        var first = rowEvents((0..<rows).map { ($0, "line \($0 + 1) of the document") }, cols: 50)
        first.append(event("grid_cursor_goto", .array([.int(1), .int(2), .int(5)])))
        first.append(event("mode_change", .array([.string("normal"), .int(0)])))
        steps.append((first, (0..<rows).map { "line \($0 + 1) of the document" }.joined(separator: "\r\n") + "\u{1b}[2 q\u{1b}[3;6H\u{1b}[?25h"))
        // Scroll rows 0..<8 up by two and draw the exposed rows (Neovim's grid_scroll then grid_line).
        var scrolled: [MsgPackValue] = [event("grid_scroll", .array([.int(1), .int(0), .int(8), .int(0), .int(50), .int(2), .int(0)]))]
        scrolled += rowEvents([(6, "line 9 of the document"), (7, "line 10 of the document")], cols: 50)
        steps.append((scrolled, "\u{1b}[1;8r\u{1b}[2S\u{1b}[r\u{1b}[7;1Hline 9 of the document\u{1b}[K\u{1b}[8;1Hline 10 of the document\u{1b}[K\u{1b}[3;6H"))
        // Scroll back down by one.
        var down: [MsgPackValue] = [event("grid_scroll", .array([.int(1), .int(0), .int(8), .int(0), .int(50), .int(-1), .int(0)]))]
        down += rowEvents([(0, "line 2 of the document")], cols: 50)
        steps.append((down, "\u{1b}[1;8r\u{1b}[1T\u{1b}[r\u{1b}[1;1Hline 2 of the document\u{1b}[K\u{1b}[3;6H"))
        // Cursor shapes per mode and a cursor move.
        steps.append(([event("mode_change", .array([.string("insert"), .int(1)])), event("grid_cursor_goto", .array([.int(1), .int(4), .int(9)]))],
                      "\u{1b}[6 q\u{1b}[5;10H"))
        steps.append(([event("mode_change", .array([.string("replace"), .int(2)])), event("grid_cursor_goto", .array([.int(1), .int(1), .int(0)]))],
                      "\u{1b}[4 q\u{1b}[2;1H"))
        try assertParity(steps: steps)
    }

    @MainActor
    func testReinstalledRowsAreDrawnFromCachedGeometryWithIdenticalPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        let gpuPreference = TerminalRenderingPreferences.shared.useGPU
        TerminalRenderingPreferences.shared.setUseGPU(false)
        defer { TerminalView.allowsMetalFrameCapture = false; TerminalRenderingPreferences.shared.setUseGPU(gpuPreference) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeGridRows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathA = directory.appendingPathComponent("a.txt").path, pathB = directory.appendingPathComponent("b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: pathA)); try Data("b".utf8).write(to: URL(fileURLWithPath: pathB))

        let native = CodeTerminalView(frame: .zero)
        let host = window(native)
        defer { host.close() }
        native.nativeForegroundColor = NSColor(hex: 0xd8d8d8); native.nativeBackgroundColor = NSColor(hex: 0x181818)
        try native.setUseMetal(true)
        var profiles: [[String: Double]] = []
        native.metalPreparationProfile = { profiles.append($0) }
        let cols = native.getTerminal().cols, rows = native.getTerminal().rows
        let presenter = NativeGridPresenter(client: NeovimGridClient(socketPath: "/nonexistent"))
        presenter.prepareTerminal(native)

        func screen(_ prefix: String, hl: Int) -> NativeGridItem {
            let model = NeovimGridModel(cols: cols, rows: rows)
            var events: [MsgPackValue] = [event("grid_resize", .array([.int(1), .int(Int64(cols)), .int(Int64(rows))])),
                                          event("default_colors_set", .array([.int(0xd8d8d8), .int(0x181818), .int(-1), .int(-1), .int(-1)])),
                                          event("hl_attr_define", .array([.int(1), map([("foreground", .int(0xcc9595))]), .map([]), .array([])])),
                                          event("hl_attr_define", .array([.int(2), map([("foreground", .int(0xa8ccdf)), ("bold", .bool(true))]), .map([]), .array([])]))]
            for row in 0..<rows {
                let text = "\(prefix) row \(row) the quick brown fox 界"
                events.append(event("grid_line", gridLine(row: row, column: 0, cells: text.map { cell(String($0), row % 3 == 0 ? hl : 0) } + [cell(" ", 0, max(1, cols - text.count))])))
            }
            events.append(event("grid_cursor_goto", .array([.int(1), .int(0), .int(0)])))
            model.apply(redraw: events)
            return .frame(model.takeFrame()!)
        }
        func push(_ items: NativeGridItem...) { items.forEach { presenter.client.mailbox.push($0) }; presenter.drain() }
        func drawn(_ label: String = "") throws -> (pixels: [UInt8], rebuilt: Double, cached: Double) {
            // Let the view's own scheduled display update run first, as the display deadline does in the app:
            // it publishes the dirty range that the next draw consumes together with the moved-line set.
            profiles.removeAll()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let image = try capture(native)
            // Another display-update draw may follow the explicit one; count every draw of this step.
            let rebuilt = profiles.reduce(0) { $0 + ($1["rowsRebuilt"] ?? 0) }, cached = profiles.reduce(0) { $0 + ($1["rowsCached"] ?? 0) }
            return (pixels(image), rebuilt, cached)
        }

        push(screen("ALPHA", hl: 1))
        let first = try drawn("first")
        XCTAssertGreaterThan(first.rebuilt, 0)
        // Leave A while hidden: its rows are detached for later instead of being overwritten.
        native.isHidden = true
        push(.leave(path: pathA, mode: "i", popupVisible: false, diagnostics: true))
        XCTAssertEqual(presenter.cache.entries[pathA]?.lines.count, rows, "the displayed rows are retained with the image")
        push(screen("BRAVO", hl: 2), .selection(token: 1, path: pathB))
        native.isHidden = false
        let bravo = try drawn("bravo")
        XCTAssertNotEqual(bravo.pixels, first.pixels)
        native.isHidden = true
        push(.leave(path: pathB, mode: "i", popupVisible: false, diagnostics: true))
        XCTAssertEqual(presenter.cache.entries[pathB]?.lines.count, rows)
        // Return to A: the retained rows are installed at once; no row is rebuilt and the pixels are identical.
        XCTAssertTrue(presenter.speculate(path: pathA, token: 2))
        XCTAssertEqual(presenter.geometryReuses, 1)
        native.isHidden = false
        let again = try drawn("again")
        XCTAssertEqual(again.rebuilt, 0, "cached geometry is reused for every row")
        XCTAssertGreaterThanOrEqual(again.cached, Double(rows))
        XCTAssertEqual(again.pixels, first.pixels, "identical pixels to the first time A was drawn")
        // Neovim's confirmation (the same screen) leaves the rows untouched.
        push(screen("ALPHA", hl: 1), .selection(token: 2, path: pathA))
        XCTAssertEqual(presenter.phase, .live)
        let confirmed = try drawn("confirmed")
        XCTAssertEqual(confirmed.pixels, first.pixels)
        XCTAssertEqual(confirmed.rebuilt, 0, "an unchanged confirmation rewrites no row")
        // Rows retained for B are still valid after A's round trip.
        XCTAssertTrue(presenter.speculate(path: pathB, token: 3))
        push(screen("BRAVO", hl: 2), .selection(token: 3, path: pathB))
        let backToB = try drawn("backToB")
        XCTAssertEqual(backToB.pixels, bravo.pixels)
        XCTAssertEqual(backToB.rebuilt, 0)
    }

    @MainActor
    func testHorizontalBandWithARetainedLayerMatchesTheScrolledContentPixelForPixel() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        let gpuPreference = TerminalRenderingPreferences.shared.useGPU
        TerminalRenderingPreferences.shared.setUseGPU(false)
        defer { TerminalView.allowsMetalFrameCapture = false; TerminalRenderingPreferences.shared.setUseGPU(gpuPreference) }
        let banded = TerminalView(frame: .zero), reference = TerminalView(frame: .zero)
        let windows = [window(banded), window(reference)]
        defer { windows.forEach { $0.close() } }
        for view in [banded, reference] {
            view.nativeForegroundColor = NSColor(hex: 0xd8d8d8); view.nativeBackgroundColor = NSColor(hex: 0x181818)
            try view.setUseMetal(true)
        }
        let cols = banded.getTerminal().cols, rows = banded.getTerminal().rows, gutter = 4
        func text(row: Int, leftcol: Int) -> String {
            let long = (0..<20).map { "r\(row)w\($0)\u{1b}[38;2;204;149;149m界\u{1b}[0m-" }.joined()
            // Strip to the visible slice by columns, counting the double-width character as two.
            var visible = "", column = 0, skipping = leftcol
            var index = long.startIndex
            while index < long.endIndex, column < cols - gutter {
                if long[index] == "\u{1b}" {
                    let end = long[index...].firstIndex(of: "m")!
                    visible += long[index...end]; index = long.index(after: end); continue
                }
                let width = long[index] == "界" ? 2 : 1
                if skipping > 0 { skipping -= width; index = long.index(after: index); if skipping < 0 { visible += " "; column += 1 }; continue }
                if column + width > cols - gutter { break }
                visible.append(long[index]); column += width; index = long.index(after: index)
            }
            return visible
        }
        func screen(leftcol: Int) -> String {
            "\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[H" + (0..<rows).map { row in "\u{1b}[0m" + String(format: "%3d ", row + 1) + text(row: row, leftcol: leftcol) }.joined(separator: "\r\n")
        }
        // The band shows leftcol 10, those rows are retained, and Neovim's answer for leftcol 18 is written.
        banded.feed(text: screen(leftcol: 10))
        _ = try capture(banded)
        var retained: [BufferLine] = []
        banded.externalGridUpdate { terminal in
            retained = banded.externalGridExchange((0..<rows).map { _ in BufferLine(cols: cols) }) ?? []
        }
        banded.feed(text: "\u{1b}[H" + (0..<rows).map { row in "\u{1b}[0m" + String(format: "%3d ", row + 1) + text(row: row, leftcol: 18) }.joined(separator: "\r\n"))
        XCTAssertEqual(retained.count, rows)
        // Drawn at leftcol 13: the current rows move right by 5 columns, the retained rows fill the 5 exposed columns.
        let cell = CGFloat(try XCTUnwrap(banded.cellSizeInPixels(source: banded.getTerminal())).width) / (banded.window?.backingScaleFactor ?? 2)
        let start = CGFloat(gutter) * cell, end = CGFloat(cols) * cell
        banded.externalHorizontalScroll = ExternalHorizontalScroll(rows: 0...(rows - 1), textStart: gutter, textEnd: cols, layers: [
            .init(lines: nil, offset: 5 * cell, clipFrom: start + 5 * cell, clipTo: end),
            .init(lines: retained, offset: -3 * cell, clipFrom: start, clipTo: start + 5 * cell),
        ])
        reference.feed(text: screen(leftcol: 13))
        let expected = pixels(try capture(reference)), actual = pixels(try capture(banded))
        let differing = zip(actual, expected).filter { $0 != $1 }.count
        if differing > 0 {
            let width = Int(banded.bounds.width * (banded.window?.backingScaleFactor ?? 2))
            var cells = Set<String>()
            let cw = Int(cell * 2), ch = try XCTUnwrap(banded.cellSizeInPixels(source: banded.getTerminal())).height
            for index in 0..<actual.count where actual[index] != expected[index] { let p = index / 4; cells.insert("\(p % width / cw),\(p / width / ch)") }
            print("BANDDIFF", cells.sorted().prefix(40))
        }
        XCTAssertEqual(differing, 0, "\(differing) bytes differ between the banded composite and the directly drawn scrolled content")
        // With the band removed, the view shows exactly Neovim's answer (leftcol 18).
        banded.externalHorizontalScroll = nil
        let other = TerminalView(frame: .zero)
        let third = window(other); defer { third.close() }
        other.nativeForegroundColor = NSColor(hex: 0xd8d8d8); other.nativeBackgroundColor = NSColor(hex: 0x181818)
        try other.setUseMetal(true)
        other.feed(text: screen(leftcol: 18))
        XCTAssertEqual(pixels(try capture(banded)), pixels(try capture(other)))
    }
}

extension Array where Element == UInt8 {
    func chunked(by size: Int) -> [[UInt8]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}