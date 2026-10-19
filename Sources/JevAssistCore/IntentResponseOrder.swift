import Foundation

/// Apply paired source selections atomically. Slow parallel answers cannot
/// restore previous anchors, including after cancellation or identical repeats.
public struct IntentResponseOrder: Sendable {
    private var goalOrder = GoalResponseOrder()
    private var taskOrder = GoalResponseOrder()
    public init() {}

    public mutating func accept(sequence: UInt64, selection: IntentSelection,
                                requestedPrevious: IntentSelection, current: IntentSelection,
                                requestedConversation: SessionTranscript, currentConversation: SessionTranscript,
                                requestedUtterance: String?, currentUtterance: String?) -> Bool {
        guard requestedPrevious == current,
              GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: nil,
                conversation: requestedConversation, currentConversation: currentConversation,
                requestedUtterance: requestedUtterance, currentUtterance: currentUtterance) else { return false }
        // A keep-previous result must refer to the same source occurrence.
        for anchor in [current.goal, current.task].compactMap({ $0 }) {
            guard requestedConversation.sourceIdentity(of: anchor) == currentConversation.sourceIdentity(of: anchor) else { return false }
        }
        var nextGoal = goalOrder, nextTask = taskOrder
        guard nextGoal.accept(sequence: sequence, selection: selection.goal,
            requestedTranscript: requestedConversation.text, currentTranscript: currentConversation.text,
            requestedConversation: requestedConversation, currentConversation: currentConversation,
            recoveryUtterance: currentUtterance),
              nextTask.accept(sequence: sequence, selection: selection.task,
            requestedTranscript: requestedConversation.text, currentTranscript: currentConversation.text,
            requestedConversation: requestedConversation, currentConversation: currentConversation,
            recoveryUtterance: currentUtterance) else { return false }
        goalOrder = nextGoal; taskOrder = nextTask
        return true
    }
}
