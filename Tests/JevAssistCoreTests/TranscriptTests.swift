import XCTest
@testable import JevAssistCore

final class TranscriptTests: XCTestCase {
    func testRecognitionHistoryAndInputChronology() throws {
        try TranscriptChecks.run { condition, message in XCTAssertTrue(condition, message) }
    }
}
