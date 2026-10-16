import Foundation
import CoreGraphics
import JevAssistCore

/// Synthetic recordings under a unique temporary folder. Never reads a real
/// recording, requests permissions, captures a screen, or starts a microphone.
@MainActor
enum SessionRecorderChecks {
    static func run() -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jev-recording-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let budget = RecordingQueueBudget(maxBytes: 100, maxItems: 2)
            expect(budget.reserve(60), "recording queue admits bounded evidence")
            expect(!budget.reserve(41), "recording queue bounds retained JPEG bytes")
            expect(budget.reserve(40) && !budget.reserve(0), "recording queue also bounds event count")
            budget.release(60)
            expect(budget.reserve(60), "writer completion releases queue capacity")

            let recordings = root.appendingPathComponent("recordings")
            let recorder = SessionRecorder(rootURL: recordings)
            recorder.start(sessionID: UUID())
            recorder.recordContext(transcript: "Find the synthetic attachment", goal: nil)
            recorder.recordContext(transcript: "Find the synthetic attachment", goal: nil)
            let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 0xff, 0xd9])
            let frame = ScreenSnapshot(windowID: 7, processID: 1, bundleID: "fixture.app", appName: "Fixture",
                                       windowTitle: "Synthetic page", screenBounds: CGRect(x: -400, y: 30, width: 800, height: 500),
                                       jpeg: jpeg, fingerprint: [], imageContentRect: CGRect(x: 0, y: 0.1, width: 1, height: 0.8),
                                       surfaceIDs: [7])
            let first = recorder.recordFrame(frame, generation: 2)
            let second = recorder.recordFrame(frame, generation: 2)
            expect(first != nil && second != nil && first != second, "requests receive distinct frame references")
            let box = NormalizedBox(top: 0.2, bottom: 0.4, left: 0.3, right: 0.6)
            let ensemble = BoxEnsemble(samples: [
                BoxSample(box: NormalizedBox(top: 0.18, bottom: 0.38, left: 0.28, right: 0.58), confidence: 0.81, presence: 0.91),
                BoxSample(box: NormalizedBox(top: 0.22, bottom: 0.42, left: 0.32, right: 0.62), confidence: 0.79, presence: 0.9),
                BoxSample(box: NormalizedBox(top: 0.7, bottom: 0.9, left: 0.7, right: 0.9), confidence: 0.99, presence: 0.95)
            ], selectedIndices: [0, 1], method: "weighted_agreement", iouThreshold: 0.5)
            recorder.recordDecision(requestID: "synthetic-request", frameID: first,
                                    result: GuidanceResult(box: box, confidence: 0.8, presence: 0.9, ensemble: ensemble),
                                    latencyMS: 145, disposition: "displayed", reason: "accepted", targetRect: frame.screenRect(for: box))
            recorder.recordDecision(requestID: "synthetic-disagreement", frameID: second,
                                    result: GuidanceResult(box: nil, confidence: 0, presence: 0.9,
                                                           ensemble: BoxEnsemble(samples: ensemble.samples, selectedIndices: [], method: "no_agreement", iouThreshold: 0.5)),
                                    latencyMS: 160, disposition: "suppressed", reason: "no_agreement")
            recorder.recordHighlight(reason: "accepted", frameID: first, box: box, targetRect: frame.screenRect(for: box))
            recorder.recordContext(transcript: "Find the synthetic attachment", goal: "synthetic attachment")
            recorder.recordContext(transcript: "Find the synthetic attachment", goal: nil)
            recorder.recordContext(transcript: String(repeating: "x", count: 30_000), goal: nil)
            recorder.recordSetting(name: "guidance_pace", value: "fast")
            recorder.recordSetting(name: "box_sampling", value: "consensus")
            recorder.recordSetting(name: "api_key", value: "synthetic-credential-must-not-appear")
            recorder.recordDecision(requestID: "invalid-numeric", frameID: nil,
                                    result: GuidanceResult(box: nil, confidence: .nan, presence: .infinity,
                                                           ensemble: BoxEnsemble(samples: [BoxSample(box: nil, confidence: .nan, presence: .infinity)],
                                                                                 selectedIndices: [], method: "invalid_fixture", iouThreshold: 0.5)),
                                    latencyMS: .nan, disposition: "suppressed", reason: "invalid_fixture")
            recorder.stop()
            expect(recorder.recordFrame(frame, generation: 3) == nil, "stopped sessions admit no screenshots")
            recorder.flushForTesting()
            let run = try sessionFolders(recordings).first!
            let images = try fm.contentsOfDirectory(at: run.appendingPathComponent("frames"), includingPropertiesForKeys: nil)
            expect(images.count == 1, "identical prepared JPEGs are stored once")
            let storedJPEG = try Data(contentsOf: images[0])
            expect(storedJPEG == jpeg, "replay preserves exact request image bytes")
            let data = try Data(contentsOf: run.appendingPathComponent("events.ndjson"))
            let text = String(decoding: data, as: UTF8.self)
            let events = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            expect(events.enumerated().allSatisfy { ($0.element["sequence"] as? Int) == $0.offset + 1 }, "replay sequence preserves event order")
            expect(events.first?["kind"] as? String == "session_started" && events.last?["kind"] as? String == "session_stopped", "recording has explicit session boundaries")
            let contexts = events.filter { $0["kind"] as? String == "context" }
            expect(contexts.count == 4 && contexts[2]["goal"] == nil, "context dedup retains goal selection and clearing")
            expect((contexts.last?["transcript"] as? String)?.count == TranscriptContext.maximumCharacters, "recordings retain the complete bounded conversation context")
            let decision = events.first { $0["requestID"] as? String == "synthetic-request" }!
            expect(decision["frameID"] as? String == first && decision["latencyMS"] as? Double == 145, "decisions link exact frames and latency")
            expect(decision["box"] != nil && decision["targetRect"] != nil && decision["presence"] as? Double == 0.9, "replay includes model and desktop target coordinates")
            let recordedEnsemble = decision["ensemble"] as! [String: Any]
            let decodedEnsemble = try JSONDecoder().decode(BoxEnsemble.self, from: JSONSerialization.data(withJSONObject: recordedEnsemble))
            expect(decodedEnsemble == ensemble, "recording preserves every original sample box and probability in order")
            expect(recordedEnsemble["selected_indices"] as? [Int] == [0, 1] && recordedEnsemble["iou_threshold"] as? Double == 0.5,
                   "recorded consensus retains snake-case selected indices and IoU threshold")
            let recordedFinal = try JSONDecoder().decode(NormalizedBox.self, from: JSONSerialization.data(withJSONObject: decision["box"]!))
            expect(recordedFinal == box, "sample recording does not replace or recompute the final box")
            let disagreement = events.first { $0["requestID"] as? String == "synthetic-disagreement" }!
            expect(disagreement["box"] == nil && (disagreement["ensemble"] as? [String: Any])?["method"] as? String == "no_agreement",
                   "suppressed disagreement keeps its original sample evidence without inventing a final box")
            expect(events.contains { $0["settingName"] as? String == "box_sampling" && $0["settingValue"] as? String == "consensus" },
                   "box sampling mode changes are recorded")
            expect(events.contains { $0["requestID"] as? String == "invalid-numeric" }, "nonfinite metrics cannot break the recording stream")
            let invalid = events.first { $0["requestID"] as? String == "invalid-numeric" }!
            let invalidSamples = (invalid["ensemble"] as? [String: Any])?["samples"] as? [[String: Any]]
            expect(invalidSamples?.first?["confidence"] as? String == "NaN", "malformed sample evidence stays inspectable without breaking recording")
            expect(!text.contains("synthetic-credential-must-not-appear") && !text.contains("api_key"), "operational recording API rejects credential setting fields")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("manifest.json"))) as! [String: Any]
            expect(manifest["rawAudio"] as? Bool == false, "recording explicitly excludes raw microphone audio")
            expect(fm.fileExists(atPath: run.appendingPathComponent("review.html").path), "each recording includes its offline replay viewer")
            let directoryModes = try [permissions(recordings), permissions(run)]
            let fileModes = try [permissions(images[0]), permissions(run.appendingPathComponent("events.ndjson"))]
            expect(directoryModes.allSatisfy { $0 == 0o700 }, "recording directories are owner-only")
            expect(fileModes.allSatisfy { $0 == 0o600 }, "recording files are owner-only")

            var limits = RecordingLimits()
            limits.sessions = 1
            let retentionRoot = root.appendingPathComponent("retention")
            let retention = SessionRecordingWriter(root: retentionRoot, limits: limits)
            try retention.start(token: UUID(), sessionID: UUID())
            retention.close()
            let old = try sessionFolders(retentionRoot).first!
            try retention.start(token: UUID(), sessionID: UUID())
            retention.close()
            let retained = try sessionFolders(retentionRoot)
            expect(retained.count == 1 && !fm.fileExists(atPath: old.path), "retention removes the oldest completed run")

            limits.sessionBytes = 32_000
            limits.totalBytes = 35_000
            let cappedRoot = root.appendingPathComponent("capped")
            let capped = SessionRecordingWriter(root: cappedRoot, limits: limits)
            try capped.start(token: UUID(), sessionID: UUID())
            var quotaRejected = false
            do { try capped.appendFrame(RecordingEvent(kind: "frame", timestampMS: 0, elapsedMS: 0), jpeg: Data(repeating: 1, count: 40_000)) }
            catch { quotaRejected = true }
            capped.close()
            expect(quotaRejected, "per-run storage limit rejects a frame before writing it")
            let cappedRun = try sessionFolders(cappedRoot).first!
            let cappedFrames = try fm.contentsOfDirectory(atPath: cappedRun.appendingPathComponent("frames").path)
            expect(cappedFrames.isEmpty, "oversized evidence leaves no partial frame")

            let lockedRoot = root.appendingPathComponent("locked")
            let firstWriter = SessionRecordingWriter(root: lockedRoot, limits: RecordingLimits())
            let secondWriter = SessionRecordingWriter(root: lockedRoot, limits: RecordingLimits())
            try firstWriter.start(token: UUID(), sessionID: UUID())
            var competingWriterRejected = false
            do { try secondWriter.start(token: UUID(), sessionID: UUID()) }
            catch { competingWriterRejected = true }
            expect(competingWriterRejected, "a second app cannot prune or overwrite a live recording")
            firstWriter.close()
            try secondWriter.start(token: UUID(), sessionID: UUID())
            expect(secondWriter.token != nil, "stopping a run releases its writer lock")
            secondWriter.close()

            let badRoot = root.appendingPathComponent("not-a-directory")
            try Data("fixture".utf8).write(to: badRoot)
            let failedRecorder = SessionRecorder(rootURL: badRoot)
            failedRecorder.start(sessionID: UUID())
            failedRecorder.recordContext(transcript: "synthetic", goal: nil)
            failedRecorder.flushForTesting()
            failedRecorder.stop()
            failedRecorder.flushForTesting()
            let untouched = try String(contentsOf: badRoot)
            expect(untouched == "fixture", "disk failure leaves existing data intact and does not throw into guidance")

            let link = root.appendingPathComponent("linked-recordings")
            try fm.createSymbolicLink(at: link, withDestinationURL: recordings)
            let linkedWriter = SessionRecordingWriter(root: link, limits: RecordingLimits())
            var linkRejected = false
            do { try linkedWriter.start(token: UUID(), sessionID: UUID()) }
            catch { linkRejected = true }
            linkedWriter.close()
            expect(linkRejected, "recordings do not follow a replaced root symlink")
            expect(!SessionRecorder.isDeveloperCheckout(root), "distribution-style folders do not enable recording by default")
            let checkout = root.appendingPathComponent("checkout")
            for path in [".git", "Package.swift", "Sources/JevAssist/SessionController.swift", "engine/Cargo.toml"] {
                let file = checkout.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            expect(SessionRecorder.isDeveloperCheckout(checkout), "only a recognized local project checkout opts into developer recording")
        } catch {
            fputs("FAIL: synthetic recording checks failed\n", stderr)
            exit(1)
        }
        return checks
    }

    private static func sessionFolders(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
