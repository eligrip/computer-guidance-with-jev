import Foundation

/// Presents the current request using the exact goal passage selected by Jev.
/// Earlier speech remains available as history; it is never deleted or rewritten.
public struct ConversationFocus: Equatable, Sendable {
    public let currentRequest: String
    public let earlierConversation: String

    public init(transcript: String, selectedGoal: String?) {
        let boundary: String.Index
        if let selectedGoal, !selectedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let source = transcript.range(of: selectedGoal, options: .backwards) {
            boundary = source.lowerBound
        } else {
            // Until Jev has selected a request, keep the latest recognized words
            // visible. This is only a display window, not a semantic decision.
            boundary = transcript.index(transcript.endIndex, offsetBy: -min(900, transcript.count))
        }
        currentRequest = String(transcript[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        earlierConversation = String(transcript[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
