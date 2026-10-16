import Foundation

public enum TranscriptContext {
    /// Shared by recognition history and the combined user conversation.
    public static let maximumCharacters = 24_000

    public static func retainingRecent(_ text: String, maximumCharacters: Int = maximumCharacters) -> String {
        String(text.suffix(max(0, maximumCharacters)))
    }
}

/// Keeps the newest hypothesis for one recognition segment, then commits that
/// segment once. Recognition revisions never append duplicate conversation.
public struct SpeechTranscriptAccumulator: Sendable {
    public let maximumCharacters: Int
    private var committed = ""
    private var hypothesis = ""
    private var activeSegment: UUID?

    public init(maximumCharacters: Int = TranscriptContext.maximumCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public var text: String {
        TranscriptContext.retainingRecent([committed, hypothesis].filter { !$0.isEmpty }.joined(separator: " "),
                                          maximumCharacters: maximumCharacters)
    }

    public mutating func reset(retaining text: String = "") {
        committed = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        hypothesis = ""
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
    public mutating func updatePartial(_ text: String, segmentID: UUID) -> Bool {
        guard activeSegment == segmentID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let updated = TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)
        guard updated != hypothesis else { return false }
        hypothesis = updated
        return true
    }

    public mutating func finishSegment(_ id: UUID) {
        guard activeSegment == id else { return }
        committed = text
        hypothesis = ""
        activeSegment = nil
    }
}
