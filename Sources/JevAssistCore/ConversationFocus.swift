import Foundation

/// Presents the current request using the exact goal passage selected by Jev.
/// Earlier speech remains available as history; it is never deleted or rewritten.
public struct ConversationFocus: Equatable, Sendable {
    public let currentRequest: String
    public let earlierConversation: String

    public init(transcript: String, selectedGoal: String?, currentUtterance: String? = nil) {
        var boundary: String.Index
        if let selectedGoal, !selectedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let source = transcript.range(of: selectedGoal, options: .backwards) {
            boundary = source.lowerBound
        } else {
            // Until Jev has selected a request, keep the latest recognized words
            // visible. This is only a display window, not a semantic decision.
            boundary = transcript.index(transcript.endIndex, offsetBy: -min(900, transcript.count))
        }
        if let utterance = currentUtterance?.trimmingCharacters(in: .whitespacesAndNewlines), !utterance.isEmpty,
           let source = transcript.range(of: utterance, options: .backwards),
           transcript[source.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The current audio utterance can advance before goal inference has
            // returned. Keep all earlier speech available in the history view.
            boundary = selectedGoal.flatMap { transcript.range(of: $0, options: .backwards) }
                .map { max($0.lowerBound, source.lowerBound) } ?? source.lowerBound
        }
        currentRequest = String(transcript[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        earlierConversation = String(transcript[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
