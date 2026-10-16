import Foundation

public enum TranscriptContext {
    /// Shared by recognition history and the combined user conversation.
    public static let maximumCharacters = 24_000

    public static func retainingRecent(_ text: String, maximumCharacters: Int = maximumCharacters) -> String {
        String(text.suffix(max(0, maximumCharacters)))
    }
}

/// Times are relative to one recognition request's audio, not callback arrival.
/// Zero-length or invalid ranges cannot establish an utterance boundary.
public struct SpeechTranscriptAudioRange: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init?(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        self.start = start
        self.end = end
    }

    /// An unfinished trailing word may have zero duration while earlier words
    /// already establish the audio interval. It must not erase that evidence.
    public static func covering(_ segments: [SpeechTranscriptSegmentTiming]) -> Self? {
        guard let first = segments.first,
              segments.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration >= 0 }),
              segments.contains(where: { $0.duration > 0 }),
              zip(segments, segments.dropFirst()).allSatisfy({ $0.start <= $1.start }),
              let end = segments.map({ $0.start + $0.duration }).max() else { return nil }
        return Self(start: first.start, end: end)
    }
}

public struct SpeechTranscriptSegmentTiming: Equatable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval
    public let sourceRange: NSRange?
    public init(start: TimeInterval, duration: TimeInterval, sourceRange: NSRange? = nil) {
        self.start = start; self.duration = duration; self.sourceRange = sourceRange
    }
}

public enum SpeechTranscriptFocus {
    /// Apple's cumulative hypotheses may contain several spoken turns. A measured
    /// pause can focus the latest one without discarding the complete hypothesis.
    /// If timing or source ranges are unavailable, preserve the source as-is.
    public static func currentUtterance(in text: String, segments: [SpeechTranscriptSegmentTiming],
                                        minimumPause: TimeInterval = 0.8) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard minimumPause.isFinite, minimumPause > 0,
              SpeechTranscriptAudioRange.covering(segments) != nil else { return text }
        var boundary: String.Index?
        for (previous, current) in zip(segments, segments.dropFirst()) {
            guard previous.duration > 0,
                  current.start - (previous.start + previous.duration) >= minimumPause else { continue }
            guard let sourceRange = current.sourceRange, let range = Range(sourceRange, in: text), !range.isEmpty else { return text }
            boundary = range.lowerBound
        }
        return boundary.map { String(text[$0...]) } ?? text
    }
}

/// The focus is an exact source passage, never a generated goal or token window.
public struct SpeechTranscriptUpdate: Equatable, Sendable {
    public let text: String
    public let currentUtterance: String?

    public init(text: String, currentUtterance: String?) {
        self.text = text
        self.currentUtterance = currentUtterance.flatMap {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.hasSuffix($0) ? $0 : nil
        }
    }
}

/// Timing and counts only: no recognized text, audio, filenames or credentials.
public struct SpeechRecognitionTelemetry: Codable, Sendable {
    public let recognitionID: String
    public let callbackDelayMS: Double
    public let processingMS: Double
    public let audioEndToCallbackMS: Double?
    public let segmentCount: Int
    public let timedSegmentCount: Int
    public let sourceCharacters: Int
    public let transcriptCharacters: Int
    public let currentUtteranceCharacters: Int
    public let isFinal: Bool
    public let emittedUpdate: Bool

    public init(recognitionID: String, callbackDelayMS: Double, processingMS: Double, audioEndToCallbackMS: Double?,
                segmentCount: Int, timedSegmentCount: Int, sourceCharacters: Int, transcriptCharacters: Int,
                currentUtteranceCharacters: Int, isFinal: Bool, emittedUpdate: Bool) {
        self.recognitionID = recognitionID
        self.callbackDelayMS = callbackDelayMS
        self.processingMS = processingMS
        self.audioEndToCallbackMS = audioEndToCallbackMS
        self.segmentCount = segmentCount
        self.timedSegmentCount = timedSegmentCount
        self.sourceCharacters = sourceCharacters
        self.transcriptCharacters = transcriptCharacters
        self.currentUtteranceCharacters = currentUtteranceCharacters
        self.isFinal = isFinal
        self.emittedUpdate = emittedUpdate
    }
}

/// Apple may return only the current utterance within a still-running request.
/// Nonoverlapping audio ranges preserve earlier utterances; overlapping ranges
/// replace hypotheses. Text length, pauses and callback timing are not evidence
/// of a new utterance. Recognition request restarts commit their history once.
public struct SpeechTranscriptAccumulator: Sendable {
    private struct Utterance: Sendable {
        let text: String
        let audioRange: SpeechTranscriptAudioRange
        let focus: String?
    }

    public let maximumCharacters: Int
    private var committed = ""
    private var committedCurrentUtterance: String?
    private var utterances: [Utterance] = []
    private var untimedHypothesis: String?
    private var untimedFocus: String?
    private var activeSegment: UUID?

    public init(maximumCharacters: Int = TranscriptContext.maximumCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public var text: String {
        // Untimed results retain the original replacement semantics. Keep the
        // timed evidence internally so a later located result can restore its
        // earlier utterances without guessing from a short partial string.
        let hypothesis = untimedHypothesis ?? utterances.map(\.text).joined(separator: "\n")
        return TranscriptContext.retainingRecent([committed, hypothesis].filter { !$0.isEmpty }.joined(separator: "\n"),
                                          maximumCharacters: maximumCharacters)
    }

    public var update: SpeechTranscriptUpdate {
        let focus = untimedHypothesis != nil ? untimedFocus : utterances.last.map(\.focus) ?? committedCurrentUtterance
        return SpeechTranscriptUpdate(text: text, currentUtterance: focus)
    }

    public var currentUtterance: String? { update.currentUtterance }

    public mutating func reset(retaining text: String = "") {
        committed = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        committedCurrentUtterance = committed.split(separator: "\n").last.map(String.init)
        utterances = []
        untimedHypothesis = nil
        untimedFocus = nil
        activeSegment = nil
    }

    public mutating func beginSegment(_ id: UUID) {
        guard activeSegment != id else { return }
        if let activeSegment { finishSegment(activeSegment) }
        activeSegment = id
    }

    /// Empty final/error results must not erase the last words already heard.
    /// Stale callbacks from a replaced recognition task are ignored.
    @discardableResult
    public mutating func updatePartial(_ text: String, segmentID: UUID,
                                      audioRange: SpeechTranscriptAudioRange? = nil,
                                      currentUtterance: String? = nil) -> Bool {
        guard activeSegment == segmentID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let previous = update
        let updated = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        let focus = SpeechTranscriptUpdate(text: updated, currentUtterance: currentUtterance ?? updated).currentUtterance
        if let audioRange {
            // A cumulative result overlaps all of its previous utterances and
            // replaces them once. A correction of an earlier utterance does not
            // remove later speech whose audio lies outside that result.
            let first = utterances.firstIndex { $0.audioRange.end > audioRange.start } ?? utterances.endIndex
            var end = first
            while end < utterances.endIndex && utterances[end].audioRange.start < audioRange.end { end += 1 }
            utterances.replaceSubrange(first..<end, with: [Utterance(text: updated, audioRange: audioRange, focus: focus)])
            untimedHypothesis = nil
            untimedFocus = nil
            // Recognition tasks are short, but bound retained evidence too.
            var size = utterances.reduce(0) { $0 + $1.text.count + 1 }
            while utterances.count > 1, size - utterances[0].text.count - 1 >= maximumCharacters {
                size -= utterances.removeFirst().text.count + 1
            }
        } else {
            untimedHypothesis = updated
            untimedFocus = focus
        }
        return update != previous
    }

    public mutating func finishSegment(_ id: UUID) {
        guard activeSegment == id else { return }
        committedCurrentUtterance = currentUtterance
        committed = text
        utterances = []
        untimedHypothesis = nil
        untimedFocus = nil
        activeSegment = nil
    }
}
