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
        try ScreenSceneChecks.run { try expect($0, $1) }
        try TranscriptChecks.run { try expect($0, $1) }
        var goalOrder = GoalResponseOrder()
        try expect(GoalResponseOrder.echoesStaleAnchor(selection: "Open Mail", requestedPrevious: "Open Mail", currentGoal: "Open Maps"),
                   "Parallel keep-previous response restored a superseded goal")
        try expect(GoalResponseOrder.echoesStaleAnchor(selection: nil, requestedPrevious: nil, currentGoal: "Open Maps"),
                   "Parallel old nil anchor erased a newly selected goal")
        try expect(!GoalResponseOrder.echoesStaleAnchor(selection: "Save file", requestedPrevious: "Open Mail", currentGoal: "Open Maps"),
                   "A real newer source selection was mistaken for stale retention")
        let twoCommands = "Open mail. Save the attachment."
        try expect(goalOrder.accept(sequence: 2, selection: "Save the attachment.", requestedTranscript: twoCommands,
                                    currentTranscript: twoCommands), "Newest spoken command was rejected")
        try expect(!goalOrder.accept(sequence: 1, selection: "Open mail.", requestedTranscript: "Open mail.",
                                     currentTranscript: twoCommands), "Late old goal displaced the newer command")
        try expect(!goalOrder.accept(sequence: 3, selection: "Open mail.", requestedTranscript: "Open mail.",
                                     currentTranscript: "Open Maps."), "Corrected-away speech restored an old goal")
        try expect(!goalOrder.accept(sequence: 4, selection: nil, requestedTranscript: "Open",
                                     currentTranscript: "Open Maps."), "Old abstention erased new speech")
        try expect(goalOrder.accept(sequence: 5, selection: "Open Maps.", requestedTranscript: "Open Maps.",
                                    currentTranscript: "Open Maps. Please"), "Continuous speech starved a valid goal")
        try expect(GoalResponseOrder.extendsSameCommand("Save the attachment", "Save the attachment to Downloads."),
                   "Extending a command invalidated every in-flight target")
        try expect(!GoalResponseOrder.extendsSameCommand("Open mail", "Open Maps"), "Different commands were treated as extensions")
        try expect(GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: "Open Maps", transcript: "Open Maps", currentTranscript: "Open Maps"),
                   "First goal selection suppressed a target that already saw those words")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Open mail", currentGoal: "Open Maps", transcript: "Open mail", currentTranscript: "Open mail. Open Maps"),
                   "A target that never saw the new command was accepted")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Open mail", currentGoal: nil, transcript: "Open mail", currentTranscript: "Open mail. Cancel that"),
                   "Cancelled goal allowed an old target")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Open Maps", currentGoal: "Open Mail",
            transcript: "Open Mail. Open Maps.", currentTranscript: "Open Mail. Open Maps. Open Mail."),
                   "An earlier matching phrase was confused with a repeated new command")
        try expect(GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Save it", currentGoal: "Save it to Downloads",
            transcript: "Open photo. Save it", currentTranscript: "Open photo. Save it to Downloads"),
                   "A growing partial of the same command starved guidance")
        let a = NormalizedBox(top: 0.1, bottom: 0.2, left: 0.3, right: 0.4)
        let b = NormalizedBox(top: 0.5, bottom: 0.6, left: 0.7, right: 0.8)
        let first = GuidanceResult(box: a, confidence: 0.9, presence: 0.95)
        let second = GuidanceResult(box: b, confidence: 0.9, presence: 0.95)
        let absent = GuidanceResult(box: nil, confidence: 0.9, presence: 0.1)
        var scoped = HighlightLatch()
        scoped.beginSession()
        let fullBeforeDock = scoped.makeRequest(view: .scene)!
        let newerDock = scoped.makeRequest(view: .dock)!
        try expect(!scoped.apply(absent, for: newerDock), "Absent Dock target unexpectedly latched")
        try expect(scoped.apply(first, for: fullBeforeDock), "Dock abstention suppressed a valid app target")
        let laterDock = scoped.makeRequest(view: .dock)!
        try expect(!scoped.apply(second, for: laterDock) && scoped.box == a, "Another view replaced the held box")
        let lowConfidence = scoped.makeRequest(view: .scene)!
        try expect(!scoped.apply(GuidanceResult(box: nil, confidence: 0.01, presence: 0.9), for: lowConfidence)
                   && scoped.box == a, "A low-confidence result erased the held box")
        let staleScene = scoped.makeRequest(view: .scene)!
        let staleDock = scoped.makeRequest(view: .dock)!
        scoped.screenDidChange()
        try expect(!scoped.apply(first, for: staleScene), "Old full scene survived navigation")
        try expect(!scoped.apply(second, for: staleDock), "Old Dock scene survived navigation")
        let oldDock = scoped.makeRequest(view: .dock)!
        let currentDock = scoped.makeRequest(view: .dock)!
        _ = scoped.apply(absent, for: currentDock)
        try expect(!scoped.apply(second, for: oldDock), "Newer Dock abstention did not reject older Dock result")
        let currentScene = scoped.makeRequest(view: .scene)!
        try expect(scoped.apply(first, for: currentScene), "Dock ordering blocked the full scene")
        scoped.endSession()
        scoped.beginSession()
        let restartedDock = scoped.makeRequest(view: .dock)!
        try expect(scoped.apply(second, for: restartedDock), "New session retained previous view ordering")
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
        let ensemble = try await client.guidance(EngineFixture.input("ensemble", sampling: .consensus))
        try expect(ensemble.box == a && ensemble.ensemble?.selectedIndices == [0, 1, 2], "Three-call evidence crosses the pipe intact")
        try expect(ensemble.ensemble?.samples.count == 3, "All comparison samples are retained")
        let disagreement = try await client.guidance(EngineFixture.input("ensemble-none", sampling: .consensus))
        try expect(disagreement.box == nil && disagreement.ensemble?.method == "no_agreement", "Disagreement abstains without losing evidence")
        for invalidEvidence in ["ensemble-bad", "ensemble-missing"] {
            do {
                _ = try await client.guidance(EngineFixture.input(invalidEvidence, sampling: .consensus))
                throw Failure(message: "Invalid ensemble evidence passed process boundary")
            } catch is JevError { checks += 1 }
        }
        do {
            _ = try await client.guidance(EngineFixture.input("ensemble-rate-limit", sampling: .consensus))
            throw Failure(message: "Partial batch failure was hidden")
        } catch let error as JevError {
            try expect(error.completedCalls == 2, "Successful samples are counted even when the batch fails")
            try expect(error.isRetryable && error.retryAfter == 2.5, "Partial batch preserves rate-limit backoff")
        }
        let pid1 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        let pid2 = try await client.inferGoal(transcript: "pid", previousGoal: nil)
        try expect(pid1 == pid2, "Adapter did not reuse the same Rust subprocess")
        let burst = (0..<8).map { index in Task { try await client.inferGoal(transcript: "slow:burst-\(index)", previousGoal: nil) } }
        for (index, request) in burst.enumerated() {
            let value = try await request.value
            try expect(value == "slow:burst-\(index)", "Eight bounded requests could not cross the native pipe together")
        }
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
        let staleRequests = (0..<10).map { _ in Task { try await boundedClient.inferGoal(transcript: "hang", previousGoal: nil) } }
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
