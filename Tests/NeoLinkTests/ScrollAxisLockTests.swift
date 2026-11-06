import XCTest
@testable import NeoLink

final class ScrollAxisLockTests: XCTestCase {
    func testAMostlyVerticalGestureDropsSidewaysDrift() {
        var lock = ScrollAxisLock()
        var horizontal: CGFloat = 0, vertical: CGFloat = 0
        for i in 0..<120 {
            let drift = 3.5 * CGFloat(sin(Double(i) / 9))   // up to 35% of a 10 pt vertical step
            let out = lock.filter(dx: drift, dy: -10, began: i == 0, ended: false, at: Double(i) / 60)
            horizontal += abs(out.dx); vertical += out.dy
        }
        XCTAssertEqual(horizontal, 0, "drift never reaches the program as horizontal scrolling")
        XCTAssertEqual(vertical, -1200)
        XCTAssertEqual(lock.axis, .vertical)
    }

    func testAClearlyHorizontalMovementTakesOverWithinTheGesture() {
        var lock = ScrollAxisLock()
        _ = lock.filter(dx: 1, dy: -8, began: true, ended: false, at: 0)
        let small = lock.filter(dx: 5, dy: -1, began: false, ended: false, at: 0.016)
        XCTAssertEqual(small.dx, 0, "below 6 points the lock holds")
        let clear = lock.filter(dx: 12, dy: -2, began: false, ended: false, at: 0.032)
        XCTAssertEqual(clear.dx, 12)
        XCTAssertEqual(clear.dy, 0)
        XCTAssertEqual(lock.axis, .horizontal)
    }

    func testAPauseOrANewGestureChoosesTheAxisAgain() {
        var lock = ScrollAxisLock()
        _ = lock.filter(dx: 10, dy: 1, began: true, ended: false, at: 0)
        XCTAssertEqual(lock.axis, .horizontal)
        let afterPause = lock.filter(dx: 1, dy: 9, began: false, ended: false, at: 0.1)
        XCTAssertEqual(afterPause.dx, 0)
        XCTAssertEqual(afterPause.dy, 9)
        _ = lock.filter(dx: 0, dy: 0, began: false, ended: true, at: 0.11)
        XCTAssertNil(lock.axis)
        let next = lock.filter(dx: 7, dy: 2, began: true, ended: false, at: 0.12)
        XCTAssertEqual(next.dy, 0)
    }

    func testMomentumFollowsTheLockedAxis() {
        var lock = ScrollAxisLock()
        _ = lock.filter(dx: 2, dy: -20, began: true, ended: false, at: 0)
        _ = lock.filter(dx: 0, dy: 0, began: false, ended: true, at: 0.01)
        // Momentum events have no gesture phase; the first chooses the axis from its own direction.
        var moved: CGFloat = 0
        for i in 0..<30 { moved += abs(lock.filter(dx: 3, dy: -15, began: false, ended: false, at: 0.02 + Double(i) / 120).dx) }
        XCTAssertEqual(moved, 0)
    }
}
