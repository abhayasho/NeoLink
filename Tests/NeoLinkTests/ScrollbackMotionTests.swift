import XCTest
@testable import NeoLink

final class ScrollbackMotionTests: XCTestCase {
    private struct Viewport {
        var motion = ScrollbackMotion()
        var row = 50
        var drawn: Double { Double(50 - row) + motion.offset }

        mutating func scroll(_ lines: Double) {
            let requested = motion.input(lines)
            let next = min(100, max(0, row - requested)), moved = row - next
            row = next
            motion.moved(moved, range: -Double(100 - row)...Double(row))
        }
    }

    func testSlowInputReversalsAndFastFlicksFollowTheExactDistance() {
        var viewport = Viewport(), input = 0.0
        for delta in Array(repeating: 0.04, count: 50) + [-12.75, 6.25, 0.125, -0.5, 0.125] {
            input += delta
            viewport.scroll(delta)
            XCTAssertEqual(viewport.drawn, input, accuracy: 1e-9)
            XCTAssertLessThan(abs(viewport.motion.offset), 1)
        }
    }

    func testMomentumEndAndNextGestureKeepTheFractionWithoutAnExtraGlide() {
        var viewport = Viewport()
        viewport.scroll(3.375)
        let stopped = viewport.drawn
        // End-of-finger and end-of-momentum events contain no displacement. Waiting
        // between gestures also causes no integration or automatic line alignment.
        for _ in 0..<240 { viewport.scroll(0); XCTAssertEqual(viewport.drawn, stopped) }
        viewport.scroll(0.125)
        XCTAssertEqual(viewport.drawn, 3.5, accuracy: 1e-9)
        viewport.scroll(-0.125)
        XCTAssertEqual(viewport.drawn, stopped, accuracy: 1e-9)
    }

    func testEdgesClampWithoutRetainingOverscrollOrExposingMissingRows() {
        var viewport = Viewport()
        viewport.scroll(80)
        XCTAssertEqual(viewport.row, 0); XCTAssertEqual(viewport.motion.offset, 0)
        viewport.scroll(0.75)
        XCTAssertEqual(viewport.motion.offset, 0)
        viewport.scroll(-0.25)
        XCTAssertEqual(viewport.drawn, 49.75, accuracy: 1e-9, "Reversal responds immediately at the edge")
        viewport.scroll(-80); viewport.scroll(-80)
        XCTAssertEqual(viewport.row, 100); XCTAssertEqual(viewport.motion.offset, 0)
        viewport.scroll(0.25)
        XCTAssertEqual(viewport.drawn, -49.75, accuracy: 1e-9)
    }
}
