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
