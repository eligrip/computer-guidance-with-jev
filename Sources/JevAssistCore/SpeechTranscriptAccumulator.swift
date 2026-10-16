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
}

/// Apple may return only the current utterance within a still-running request.
/// Nonoverlapping audio ranges preserve earlier utterances; overlapping ranges
/// replace hypotheses. Text length, pauses and callback timing are not evidence
/// of a new utterance. Recognition request restarts commit their history once.
public struct SpeechTranscriptAccumulator: Sendable {
    private struct Utterance: Sendable {
        let text: String
        let audioRange: SpeechTranscriptAudioRange
    }

    public let maximumCharacters: Int
    private var committed = ""
    private var utterances: [Utterance] = []
    private var untimedHypothesis: String?
    private var activeSegment: UUID?

    public init(maximumCharacters: Int = TranscriptContext.maximumCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public var text: String {
        // Untimed results retain the original replacement semantics. Keep the
        // timed evidence internally so a later located result can restore its
        // earlier utterances without guessing from a short partial string.
        let hypothesis = untimedHypothesis ?? utterances.map(\.text).joined(separator: " ")
        return TranscriptContext.retainingRecent([committed, hypothesis].filter { !$0.isEmpty }.joined(separator: " "),
                                          maximumCharacters: maximumCharacters)
    }

    public mutating func reset(retaining text: String = "") {
        committed = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        utterances = []
        untimedHypothesis = nil
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
                                      audioRange: SpeechTranscriptAudioRange? = nil) -> Bool {
        guard activeSegment == segmentID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let previous = self.text
        let updated = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        if let audioRange {
            // A cumulative result overlaps all of its previous utterances and
            // replaces them once. A correction of an earlier utterance does not
            // remove later speech whose audio lies outside that result.
            let first = utterances.firstIndex { $0.audioRange.end > audioRange.start } ?? utterances.endIndex
            var end = first
            while end < utterances.endIndex && utterances[end].audioRange.start < audioRange.end { end += 1 }
            utterances.replaceSubrange(first..<end, with: [Utterance(text: updated, audioRange: audioRange)])
            untimedHypothesis = nil
            // Recognition tasks are short, but bound retained evidence too.
            var size = utterances.reduce(0) { $0 + $1.text.count + 1 }
            while utterances.count > 1, size - utterances[0].text.count - 1 >= maximumCharacters {
                size -= utterances.removeFirst().text.count + 1
            }
        } else {
            untimedHypothesis = updated
        }
        return self.text != previous
    }

    public mutating func finishSegment(_ id: UUID) {
        guard activeSegment == id else { return }
        committed = text
        utterances = []
        untimedHypothesis = nil
        activeSegment = nil
    }
}
