import Foundation
import XCTest
@testable import JevAssistCore

final class JevClientTests: XCTestCase {
    func testRustGuidanceContractAndGatedResult() async throws {
        let fixture = try EngineFixture()
        let client = fixture.client()
        let normal = try await client.guidance(EngineFixture.input("normal"))
        XCTAssertEqual(normal.box, NormalizedBox(top: 0.1, bottom: 0.2, left: 0.3, right: 0.4))
        let absent = try await client.guidance(EngineFixture.input("absent"))
        XCTAssertNil(absent.box)
        XCTAssertEqual(absent.presence, 0.1)
    }

    func testConcurrentRepliesAndProcessReuse() async throws {
        let fixture = try EngineFixture()
        let client = fixture.client()
        let pid1 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        async let slow = client.inferGoal(transcript: "slow:first", previousGoal: nil)
        async let fast = client.inferGoal(transcript: "fast:second", previousGoal: nil)
        let results = try await (slow, fast)
        XCTAssertEqual(results.0, "slow:first")
        XCTAssertEqual(results.1, "fast:second")
        let pid2 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        XCTAssertEqual(pid1, pid2)
    }

    func testCancellationDoesNotBreakOtherRequests() async throws {
        let fixture = try EngineFixture()
        let client = fixture.client()
        let cancelled = Task { try await client.inferGoal(transcript: "slow:first", previousGoal: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Ignored cancellation") }
        catch is CancellationError { }
        let result = try await client.inferGoal(transcript: "after", previousGoal: nil)
        XCTAssertEqual(result, "after")
    }

    func testSafeErrorsAndRetryMetadata() async throws {
        let fixture = try EngineFixture()
        let client = fixture.client()
        do { _ = try await client.guidance(EngineFixture.input("rate-limit")); XCTFail("Ignored error") }
        catch let error as JevError {
            XCTAssertEqual(error.retryAfter, 2.5)
            XCTAssertTrue(error.isRetryable)
            XCTAssertFalse(error.localizedDescription.contains("private upstream"))
        }
        do { _ = try await client.guidance(EngineFixture.input("invalid-box")); XCTFail("Invalid box accepted") }
        catch is JevError { }
    }

    func testTimeoutAndProcessRestart() async throws {
        let fixture = try EngineFixture()
        let client = fixture.client(timeout: 0.2)
        do { _ = try await client.inferGoal(transcript: "hang", previousGoal: nil); XCTFail("Ignored timeout") }
        catch is JevError { }
        let result = try await client.inferGoal(transcript: "restarted", previousGoal: nil)
        XCTAssertEqual(result, "restarted")
    }
}
