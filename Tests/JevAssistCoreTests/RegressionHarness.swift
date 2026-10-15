// A portable fallback for macOS Command Line Tools installations without XCTest.
// Compile with -D JEV_ASSIST_STANDALONE_TESTS alongside Sources/JevAssistCore/*.swift.
#if JEV_ASSIST_STANDALONE_TESTS
import Foundation

@main
enum CoreRegressionHarness {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw Failure(message: message) }
    }

    static func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do { try body() } catch { return }
        throw Failure(message: message)
    }

    static func main() async throws {
        let a = NormalizedBox(top: 0.1, bottom: 0.2, left: 0.3, right: 0.4)
        let b = NormalizedBox(top: 0.5, bottom: 0.6, left: 0.7, right: 0.8)
        let first = GuidanceResult(box: a, confidence: 0.9, presence: 0.95)
        let second = GuidanceResult(box: b, confidence: 0.9, presence: 0.95)
        let absent = GuidanceResult(box: nil, confidence: 0.9, presence: 0.1)
        var latch = HighlightLatch()
        try expect(latch.makeRequest() == nil, "Inactive session issued a request")
        latch.beginSession()
        let ticket = latch.makeRequest()!
        try expect(latch.apply(first, for: ticket), "Initial box did not latch")
        for _ in 0..<1_000 {
            let newer = latch.makeRequest()!
            _ = latch.apply(absent, for: newer)
        }
        try expect(latch.box == a, "Repeated empty results erased held box")
        let afterSpeech = latch.makeRequest()!
        try expect(!latch.apply(second, for: afterSpeech) && latch.box == a, "Speech revision moved held box")
        let afterClick = latch.makeRequest()!
        try expect(afterClick.screenGeneration == ticket.screenGeneration, "Click-only observation changed generation")
        try expect(!latch.apply(second, for: afterClick) && latch.box == a, "Click-only observation lost held box")
        let oldScreen = latch.makeRequest()!
        latch.screenDidChange()
        try expect(latch.box == nil, "Changed screen retained stale box")
        try expect(!latch.apply(first, for: oldScreen), "Old screen response was accepted")
        let old = latch.makeRequest()!
        let new = latch.makeRequest()!
        _ = latch.apply(absent, for: new)
        try expect(!latch.apply(first, for: old), "Out-of-order answer was accepted")
        let current = latch.makeRequest()!
        try expect(latch.apply(second, for: current), "Changed screen could not acquire new box")
        let previousSession = latch.makeRequest()!
        latch.endSession()
        latch.beginSession()
        try expect(!latch.apply(first, for: previousSession), "Previous session answer was accepted")

        for invalid in [
            NormalizedBox(top: 0.5, bottom: 0.1, left: 0.2, right: 0.3),
            NormalizedBox(top: -0.1, bottom: 0.1, left: 0.2, right: 0.3),
            NormalizedBox(top: 0.1, bottom: 0.2, left: 0.3, right: 0.3),
            NormalizedBox(top: .nan, bottom: 0.2, left: 0.3, right: 0.4)
        ] {
            let request = latch.makeRequest()!
            let result = GuidanceResult(box: invalid, confidence: 1, presence: 1)
            try expect(!latch.apply(result, for: request), "Invalid box was accepted")
        }

        let fixture = try EngineFixture()
        let client = fixture.client()
        let decoded = try await client.guidance(EngineFixture.input("normal"))
        try expect(decoded.box == a, "Rust adapter lost documented box")
        let missing = try await client.guidance(EngineFixture.input("absent"))
        try expect(missing.box == nil && missing.presence == 0.1, "Engine gating result was lost")
        let pid1 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        let pid2 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        try expect(pid1 == pid2, "Adapter did not reuse the same Rust subprocess")
        let none = try await client.inferGoal(transcript: "none", previousGoal: "old goal")
        try expect(none == nil, "Nil goal was not preserved")
        let fragmented = try await client.inferGoal(transcript: "fragment", previousGoal: nil)
        try expect(fragmented == "fragment", "Fragmented NDJSON reply failed")
        async let slow = client.inferGoal(transcript: "slow:first", previousGoal: nil)
        async let fast = client.inferGoal(transcript: "fast:second", previousGoal: nil)
        let results = try await (slow, fast)
        try expect(results.0 == "slow:first" && results.1 == "fast:second", "Out-of-order IDs routed to wrong caller")
        do {
            _ = try await client.guidance(EngineFixture.input("rate-limit"))
            throw Failure(message: "Rate limit did not surface")
        } catch let error as JevError {
            try expect(error.isRetryable && error.retryAfter == 2.5, "Engine retry metadata lost")
            try expect(!error.localizedDescription.contains("private upstream"), "Engine HTTP error exposed upstream content")
        }
        do {
            _ = try await client.guidance(EngineFixture.input("invalid-box"))
            throw Failure(message: "Malformed box passed process boundary")
        } catch is JevError { checks += 1 }
        let cancelStart = Date()
        let cancelled = Task { try await client.inferGoal(transcript: "slow:cancel", previousGoal: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "Cancellation ignored") }
        catch is CancellationError { checks += 1 }
        try expect(Date().timeIntervalSince(cancelStart) < 0.12, "Cancellation blocked behind helper work")
        let afterCancel = try await client.inferGoal(transcript: "after-cancel", previousGoal: nil)
        try expect(afterCancel == "after-cancel", "Cancellation broke unrelated requests")
        let boundedClient = fixture.client(timeout: 2)
        let staleRequests = (0..<4).map { _ in Task { try await boundedClient.inferGoal(transcript: "hang", previousGoal: nil) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        for request in staleRequests { request.cancel() }
        for request in staleRequests { _ = try? await request.value }
        do {
            _ = try await boundedClient.inferGoal(transcript: "overflow", previousGoal: nil)
            throw Failure(message: "Cancelled remote work allowed an unbounded queue")
        } catch let error as JevError {
            try expect(error.retryAfter == 0.25, "Remote work backpressure was not surfaced")
        }
        do {
            _ = try await client.inferGoal(transcript: "malformed", previousGoal: nil)
            throw Failure(message: "Malformed output accepted")
        } catch is JevError { checks += 1 }
        let afterMalformed = try await client.inferGoal(transcript: "after-malformed", previousGoal: nil)
        try expect(afterMalformed == "after-malformed", "Process did not restart after protocol failure")
        do {
            _ = try await client.inferGoal(transcript: "crash", previousGoal: nil)
            throw Failure(message: "Helper exit hung or succeeded")
        } catch is JevError { checks += 1 }
        let afterCrash = try await client.inferGoal(transcript: "after-crash", previousGoal: nil)
        try expect(afterCrash == "after-crash", "Process did not restart after crash")
        let timeoutClient = fixture.client(timeout: 0.2)
        do {
            _ = try await timeoutClient.inferGoal(transcript: "hang", previousGoal: nil)
            throw Failure(message: "Timeout ignored")
        } catch let error as JevError { try expect(error.isRetryable, "Timeout was not recoverable") }
        let afterTimeout = try await timeoutClient.inferGoal(transcript: "after-timeout", previousGoal: nil)
        try expect(afterTimeout == "after-timeout", "Process did not restart after timeout")
        let exitClient = fixture.client(timeout: 1, mode: "exit-before-read")
        let large = GuidanceInput(transcript: "large", goal: nil, notes: "fixture notes", browserContext: "fixture browser",
                                  accessibilityContext: nil, imageJPEG: Data(repeating: 1, count: 1_000_000))
        do {
            _ = try await exitClient.guidance(large)
            throw Failure(message: "Exited helper accepted a request")
        } catch is JevError { checks += 1 }
        print("PASS: \(checks) core regression checks (no credentials or network required).")
    }
}
#endif
