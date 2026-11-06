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
