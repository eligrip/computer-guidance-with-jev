import XCTest
@testable import JevAssistCore

final class HighlightLatchTests: XCTestCase {
    private let first = NormalizedBox(top: 0.1, bottom: 0.2, left: 0.3, right: 0.4)
    private let next = NormalizedBox(top: 0.5, bottom: 0.6, left: 0.7, right: 0.8)

    private func result(_ box: NormalizedBox?) -> GuidanceResult {
        GuidanceResult(box: box, confidence: 0.9, presence: 0.95)
    }

    func testHighlightHasNoTimeoutAndContinuedEvaluationCannotRemoveIt() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let ticket = try XCTUnwrap(latch.makeRequest())
        XCTAssertTrue(latch.apply(result(first), for: ticket))
        // Any number of later observations may fail to locate a target. The
        // already displayed target has no expiration and remains on the screen.
        for _ in 0..<1_000 {
            let later = try XCTUnwrap(latch.makeRequest())
            XCTAssertFalse(latch.apply(result(nil), for: later))
        }
        XCTAssertEqual(latch.box, first)
    }

    func testSpeechOrGoalRevisionOnSameScreenPreservesExistingBox() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let initial = try XCTUnwrap(latch.makeRequest())
        latch.apply(result(first), for: initial)
        // Transcript/goal updates can start new requests, but do not imply a
        // screen generation change and cannot replace the displayed target.
        let revisedSpeech = try XCTUnwrap(latch.makeRequest())
        XCTAssertFalse(latch.apply(result(next), for: revisedSpeech))
        XCTAssertEqual(latch.box, first)
    }

    func testClickWithoutScreenChangeDoesNotAdvance() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let initial = try XCTUnwrap(latch.makeRequest())
        latch.apply(result(first), for: initial)
        // The app observes a click, then captures an identical screen. There is
        // deliberately no click-driven invalidation API on the latch.
        let afterClick = try XCTUnwrap(latch.makeRequest())
        XCTAssertEqual(afterClick.screenGeneration, initial.screenGeneration)
        XCTAssertFalse(latch.apply(result(next), for: afterClick))
        XCTAssertEqual(latch.box, first)
    }

    func testMeaningfulScreenChangeReleasesBoxAndRejectsOldScreen() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let initial = try XCTUnwrap(latch.makeRequest())
        latch.apply(result(first), for: initial)
        let oldInFlight = try XCTUnwrap(latch.makeRequest())
        latch.screenDidChange()
        XCTAssertNil(latch.box)
        XCTAssertFalse(latch.apply(result(first), for: oldInFlight))
        let current = try XCTUnwrap(latch.makeRequest())
        XCTAssertTrue(latch.apply(result(next), for: current))
        XCTAssertEqual(latch.box, next)
    }

    func testNewerEmptyResultRejectsOutOfOrderOlderBox() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let old = try XCTUnwrap(latch.makeRequest())
        let new = try XCTUnwrap(latch.makeRequest())
        XCTAssertFalse(latch.apply(result(nil), for: new))
        XCTAssertFalse(latch.apply(result(first), for: old))
        XCTAssertNil(latch.box)
        let newest = try XCTUnwrap(latch.makeRequest())
        XCTAssertTrue(latch.apply(result(next), for: newest))
    }

    func testDockAbstentionDoesNotSuppressAnOlderAppResult() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let scene = try XCTUnwrap(latch.makeRequest(view: .scene))
        let dock = try XCTUnwrap(latch.makeRequest(view: .dock))
        XCTAssertFalse(latch.apply(result(nil), for: dock))
        XCTAssertTrue(latch.apply(result(first), for: scene))
        let nextDock = try XCTUnwrap(latch.makeRequest(view: .dock))
        XCTAssertFalse(latch.apply(result(next), for: nextDock))
        XCTAssertEqual(latch.box, first)
        let uncertain = try XCTUnwrap(latch.makeRequest())
        XCTAssertFalse(latch.apply(GuidanceResult(box: nil, confidence: 0.01, presence: 0.9), for: uncertain))
        XCTAssertEqual(latch.box, first)
    }

    func testEachViewRejectsOldScreensAndOrdersItsOwnCompletions() throws {
        var latch = HighlightLatch()
        latch.beginSession()
        let scene = try XCTUnwrap(latch.makeRequest(view: .scene))
        let dock = try XCTUnwrap(latch.makeRequest(view: .dock))
        latch.screenDidChange()
        XCTAssertFalse(latch.apply(result(first), for: scene))
        XCTAssertFalse(latch.apply(result(next), for: dock))
        let oldDock = try XCTUnwrap(latch.makeRequest(view: .dock))
        let newerDock = try XCTUnwrap(latch.makeRequest(view: .dock))
        XCTAssertFalse(latch.apply(result(nil), for: newerDock))
        XCTAssertFalse(latch.apply(result(next), for: oldDock))
        let freshScene = try XCTUnwrap(latch.makeRequest(view: .scene))
        XCTAssertTrue(latch.apply(result(first), for: freshScene))
        latch.endSession()
        latch.beginSession()
        let restartedDock = try XCTUnwrap(latch.makeRequest(view: .dock))
        XCTAssertTrue(latch.apply(result(next), for: restartedDock))
    }

    func testEndedAndRestartedSessionsRejectOutstandingResults() throws {
        var latch = HighlightLatch()
        XCTAssertNil(latch.makeRequest())
        latch.beginSession()
        let previous = try XCTUnwrap(latch.makeRequest())
        latch.endSession()
        XCTAssertFalse(latch.apply(result(first), for: previous))
        XCTAssertNil(latch.makeRequest())
        latch.beginSession()
        XCTAssertFalse(latch.apply(result(first), for: previous))
        XCTAssertNil(latch.box)
    }

    func testMalformedBoxesAndNonfiniteScoresNeverLatch() throws {
        let malformed = [
            NormalizedBox(top: 0.2, bottom: 0.1, left: 0.3, right: 0.4),
            NormalizedBox(top: 0.1, bottom: 0.2, left: 0.4, right: 0.4),
            NormalizedBox(top: -0.1, bottom: 0.2, left: 0.3, right: 0.4),
            NormalizedBox(top: 0.1, bottom: 1.1, left: 0.3, right: 0.4),
            NormalizedBox(top: .nan, bottom: 0.2, left: 0.3, right: 0.4)
        ]
        var latch = HighlightLatch()
        latch.beginSession()
        for box in malformed {
            let request = try XCTUnwrap(latch.makeRequest())
            XCTAssertFalse(latch.apply(result(box), for: request))
        }
        let invalidScore = try XCTUnwrap(latch.makeRequest())
        XCTAssertFalse(latch.apply(GuidanceResult(box: first, confidence: .infinity, presence: 1),
                                   for: invalidScore))
        XCTAssertNil(latch.box)
    }
}
