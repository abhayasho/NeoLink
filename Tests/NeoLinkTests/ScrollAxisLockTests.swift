import XCTest
@testable import NeoLink

final class ScrollAxisLockTests: XCTestCase {
    func testAMostlyVerticalGestureDropsSidewaysDrift() {
        var lock = ScrollAxisLock(); lock.classic = false
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

    func testASustainedHorizontalMovementTakesOverWithinTheGestureButOneEventDoesNot() {
        var lock = ScrollAxisLock(); lock.classic = false
        _ = lock.filter(dx: 1, dy: -8, began: true, ended: false, at: 0)
        let single = lock.filter(dx: 12, dy: -2, began: false, ended: false, at: 0.016)
        XCTAssertEqual(single.dx, 0, "one sideways event does not end a vertical scroll")
        XCTAssertEqual(lock.axis, .vertical)
        var out = single
        for i in 2..<6 { out = lock.filter(dx: 12, dy: -1, began: false, ended: false, at: Double(i) * 0.016) }
        XCTAssertEqual(lock.axis, .horizontal, "a few events of clear sideways travel do")
        XCTAssertEqual(out.dx, 12)
        XCTAssertEqual(out.dy, 0)
        XCTAssertEqual(lock.switches, 1)
    }

    func testADiagonalOrWanderingFingerDoesNotFlipTheAxisEventByEvent() {
        // 45 degrees with noise that makes each axis win alternate events, at a slow finger's irregular rate.
        var lock = ScrollAxisLock(); lock.classic = false
        var time = 0.0, horizontal: CGFloat = 0
        for i in 0..<180 {
            time += i % 5 == 0 ? 0.034 : 0.0167          // gaps over 28 ms are not new gestures
            let wobble: CGFloat = i % 2 == 0 ? 2.5 : -2.5
            let out = lock.filter(dx: 6 + wobble, dy: -(6 - wobble), began: i == 0, ended: false, at: time)
            horizontal += abs(out.dx)
        }
        XCTAssertEqual(lock.switches, 0)
        XCTAssertTrue(horizontal == 0 || lock.axis == .horizontal, "the whole gesture stays on the axis it started on")
    }

    func testARestOrANewGestureChoosesTheAxisAgain() {
        var lock = ScrollAxisLock(); lock.classic = false
        _ = lock.filter(dx: 10, dy: 1, began: true, ended: false, at: 0)
        XCTAssertEqual(lock.axis, .horizontal)
        let shortGap = lock.filter(dx: 1, dy: 9, began: false, ended: false, at: 0.05)
        XCTAssertEqual(shortGap.dy, 0, "a 50 ms gap with the fingers down is the same movement")
        let afterRest = lock.filter(dx: 1, dy: 9, began: false, ended: false, at: 0.25)
        XCTAssertEqual(afterRest.dx, 0)
        XCTAssertEqual(afterRest.dy, 9)
        _ = lock.filter(dx: 0, dy: 0, began: false, ended: true, at: 0.26)
        XCTAssertNil(lock.axis)
        let next = lock.filter(dx: 7, dy: 2, began: true, ended: false, at: 0.27)
        XCTAssertEqual(next.dy, 0)
    }

    func testAPhaselessStreamChoosesAgainAfterAShortPause() {
        var lock = ScrollAxisLock(); lock.classic = false
        _ = lock.filter(dx: 10, dy: 1, began: false, ended: false, at: 0)
        let afterPause = lock.filter(dx: 1, dy: 9, began: false, ended: false, at: 0.05)
        XCTAssertEqual(afterPause.dy, 9)
    }

    func testMomentumFollowsTheLockedAxis() {
        var lock = ScrollAxisLock(); lock.classic = false
        _ = lock.filter(dx: 2, dy: -20, began: true, ended: false, at: 0)
        _ = lock.filter(dx: 0, dy: 0, began: false, ended: true, at: 0.01)
        // Momentum events have no gesture phase; the first chooses the axis from its own direction.
        var moved: CGFloat = 0
        for i in 0..<30 { moved += abs(lock.filter(dx: 3, dy: -15, began: false, ended: false, momentum: true, at: 0.02 + Double(i) / 120).dx) }
        XCTAssertEqual(moved, 0)
        // Momentum whose sideways part is larger still belongs to the vertical gesture that produced it.
        var second = ScrollAxisLock(); second.classic = false
        _ = second.filter(dx: 2, dy: -20, began: true, ended: false, at: 0)
        _ = second.filter(dx: 0, dy: 0, began: false, ended: true, at: 0.01)
        let glide = second.filter(dx: 9, dy: -6, began: false, ended: false, momentum: true, at: 0.02)
        XCTAssertEqual(glide.dx, 0)
        XCTAssertEqual(glide.dy, -6)
    }
}
