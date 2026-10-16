import Foundation

/// Goal calls may overlap as speech advances. A slower old answer cannot undo
/// a newer selection; a corrected-away passage cannot become an anchor again.
public struct GoalResponseOrder: Sendable {
    private var latestAccepted: UInt64 = 0
    public init() {}

    public static func echoesStaleAnchor(selection: String?, requestedPrevious: String?, currentGoal: String?) -> Bool {
        requestedPrevious != currentGoal && selection == requestedPrevious
    }

    /// A growing partial of the same selected phrase is not a task switch.
    public static func extendsSameCommand(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let a = first.trimmingCharacters(in: trim).lowercased()
        let b = second.trimmingCharacters(in: trim).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || b.hasPrefix(a + " ") || a.hasPrefix(b + " ")
    }

    public static func guidanceIsCurrent(requestedGoal: String?, currentGoal: String?,
                                         transcript: String, currentTranscript: String) -> Bool {
        guard let currentGoal else { return requestedGoal == nil }
        let passage: String
        if let requestedGoal, extendsSameCommand(requestedGoal, currentGoal) {
            passage = requestedGoal.count < currentGoal.count ? requestedGoal : currentGoal
        } else { passage = currentGoal }
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let search = passage.trimmingCharacters(in: trim)
        guard !search.isEmpty,
              let requested = transcript.range(of: search, options: [.backwards, .caseInsensitive]),
              let current = currentTranscript.range(of: search, options: [.backwards, .caseInsensitive]) else { return false }
        // A repeated "open it" can refer to a different object. Matching words
        // somewhere in old history do not prove this request saw that occurrence.
        return transcript[..<requested.lowerBound] == currentTranscript[..<current.lowerBound]
    }

    public mutating func accept(sequence: UInt64, selection: String?,
                                requestedTranscript: String, currentTranscript: String) -> Bool {
        guard sequence > latestAccepted else { return false }
        if let selection {
            guard !selection.isEmpty, requestedTranscript.contains(selection),
                  currentTranscript.contains(selection) else { return false }
        } else if requestedTranscript != currentTranscript {
            // An old empty answer knows nothing about the words just spoken.
            return false
        }
        latestAccepted = sequence
        return true
    }
}
