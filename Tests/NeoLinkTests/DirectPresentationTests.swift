import XCTest
@testable import NeoLink

final class DirectPresentationTests: XCTestCase {
    func testQueuedFramesCountUntilShownOrHalfARefreshPastTheirTarget() {
        let queue = QueuedDrawables()
        let period = 1.0 / 120
        let first = queue.add(target: 1.000, acquired: 0.992)
        _ = queue.add(target: 1.000 + period, acquired: 1.000)
        XCTAssertEqual(queue.count(at: 1.001, grace: period / 2), 2)
        // The first frame's refresh has passed by more than half a period: its callback may simply trail this tick.
        XCTAssertEqual(queue.count(at: 1.000 + period / 2 + 0.0001, grace: period / 2), 1)
        queue.remove(first)
        XCTAssertEqual(queue.count(at: 1.001, grace: period / 2), 1)
    }

    func testUnacknowledgedFramesAreReportedSoTheClockNeverBlocksOnADrawable() {
        let queue = QueuedDrawables()
        let id = queue.add(target: 2.0, acquired: 1.99)
        XCTAssertFalse(queue.oldestUnpresented(before: 1.98))
        XCTAssertTrue(queue.oldestUnpresented(before: 2.2), "a frame not acknowledged after 100 ms stops new drawable requests")
        queue.remove(id)
        XCTAssertFalse(queue.oldestUnpresented(before: 2.2))
        _ = queue.add(target: 3, acquired: 2.9)
        queue.reset()
        XCTAssertEqual(queue.count(at: 2.95, grace: 0.004), 0)
    }

    func testADeepStandingQueueIsDrainedOnceAndOneFrameOfSlackIsKept() {
        let queue = QueuedDrawables()
        let period = 1.0 / 120
        // Shown at the refresh after it was acquired: nothing stands in the queue.
        let onTime = queue.add(target: 1.0, acquired: 0.9925, period: period)
        queue.remove(onTime, presentedAt: 1.0004)
        XCTAssertFalse(queue.payStandingFrame())
        XCTAssertTrue(queue.isEmpty)
        // A heavy frame that missed the next refresh, or one behind a frame of slack: not drained.
        let heavy = queue.add(target: 1.5, acquired: 1.5005, period: period)
        queue.remove(heavy, presentedAt: 1.5 + 2 * period)
        XCTAssertFalse(queue.payStandingFrame())
        // Three frames drawn while three stand ahead of them: each is shown four refreshes after it was acquired.
        let ids = (0..<3).map { queue.add(target: 2.0 + Double($0) * period, acquired: 1.9995 + Double($0) * period, period: period) }
        XCTAssertFalse(queue.isEmpty)
        queue.remove(ids[0], presentedAt: 2.0 + 4 * period)
        // The frames already in flight are just as late; they must not be charged again.
        queue.remove(ids[1], presentedAt: 2.0 + 5 * period)
        XCTAssertTrue(queue.payStandingFrame())
        XCTAssertTrue(queue.payStandingFrame())
        XCTAssertFalse(queue.payStandingFrame(), "one frame of slack stays; the two beyond it cost two skipped refreshes")
        queue.remove(ids[2], presentedAt: 2.0 + 6 * period)
        XCTAssertFalse(queue.payStandingFrame(), "a frame drawn before the correction says nothing about the queue after it")
        XCTAssertEqual(queue.standingFramesDrained, 2)
    }

    func testDroppedAndImmediateFramesDoNotMeasureTheQueue() {
        let queue = QueuedDrawables()
        let dropped = queue.add(target: 1.0, acquired: 0.99, period: 1.0 / 120)
        queue.remove(dropped, presentedAt: 0)   // presentedTime 0: never shown
        let immediate = queue.add(target: 1.0, acquired: 0.99)   // no refresh it was drawn for
        queue.remove(immediate, presentedAt: 1.05)
        XCTAssertFalse(queue.payStandingFrame())
    }

    func testBookkeepingIsBounded() {
        let queue = QueuedDrawables()
        for index in 0..<50 { _ = queue.add(target: Double(index), acquired: Double(index)) }
        XCTAssertLessThanOrEqual(queue.count(at: 0, grace: 0), 8)
    }

    func testDirectPresentationIsTheDefaultAndTheDisplayLinkRemainsSelectable() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["NEOLINK_PRESENTATION"] == "link" ? NeoGPUPresentation.displayLink : .direct,
                       NeoGPUPresentation.current)
    }
}
