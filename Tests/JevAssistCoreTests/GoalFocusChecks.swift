import Foundation
#if !JEV_ASSIST_STANDALONE_TESTS
import XCTest
@testable import JevAssistCore
#endif

enum GoalFocusChecks {
    static func run(_ expect: (Bool, String) throws -> Void) throws {
        var conversation = SessionTranscript()
        conversation.updateVoice("The earlier noisy caption\nSave the report")
        let requested = conversation
        conversation.updateVoice("An earlier corrected caption\nSave the report to Downloads")
        try expect(GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Save the report", currentGoal: "Save the report to Downloads",
            conversation: requested, currentConversation: conversation,
            requestedUtterance: "Save the report", currentUtterance: "Save the report to Downloads"),
            "Earlier ASR correction starved a growing current command")
        let beforeSwitch = conversation
        conversation.updateVoice(conversation.text + "\nOpen Calendar")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Save the report", currentGoal: "Save the report",
            conversation: beforeSwitch, currentConversation: conversation,
            requestedUtterance: "Save the report to Downloads", currentUtterance: "Open Calendar"),
            "Old utterance target passed before goal inference caught up")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: nil,
            conversation: beforeSwitch, currentConversation: conversation,
            requestedUtterance: "Save the report to Downloads", currentUtterance: "Open Calendar"),
            "Nil goal let an old utterance target latch")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: nil,
            conversation: beforeSwitch, currentConversation: conversation, currentUtterance: "Open Calendar"),
            "Missing request focus let unseen new words pass")
        try expect(GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: nil,
            conversation: conversation, currentConversation: conversation, currentUtterance: "Open Calendar"),
            "Newly measured focus rejected an answer that already saw its source")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: nil, currentGoal: nil,
            conversation: beforeSwitch, currentConversation: conversation),
            "Missing focus allowed an older answer to ignore new words")
        let beforeRepeat = conversation
        conversation.updateVoice(conversation.text + "\nSave the report to Downloads")
        try expect(!GoalResponseOrder.guidanceIsCurrent(requestedGoal: "Save the report to Downloads", currentGoal: "Save the report to Downloads",
            conversation: beforeRepeat, currentConversation: conversation,
            requestedUtterance: "Save the report to Downloads", currentUtterance: "Save the report to Downloads"),
            "Repeated identical words reused a different occurrence")

        var order = GoalResponseOrder()
        var source = SessionTranscript()
        source.appendTyped("Open Mail")
        source.appendTyped("Save the report")
        func accept(_ sequence: UInt64, _ selection: String?) -> Bool {
            order.accept(sequence: sequence, selection: selection, requestedTranscript: source.text, currentTranscript: source.text,
                         requestedConversation: source, currentConversation: source)
        }
        try expect(accept(1, "Save the report"), "Newest source was rejected")
        try expect(!accept(2, "Open Mail"), "A newer RPC revived an older source")
        source.appendTyped("Cancel that")
        try expect(accept(3, nil), "Cancellation was rejected")
        try expect(!accept(4, "Save the report"), "A retired occurrence revived")
        source.appendTyped("Save the report")
        try expect(accept(5, "Save the report"), "Explicit identical request after cancellation was rejected")
        source.appendTyped("Open Mail")
        try expect(accept(6, "Open Mail"), "Explicit return to an earlier task was rejected")

        var intentOrder = IntentResponseOrder()
        var partialOrder = IntentResponseOrder()
        var partial = SessionTranscript()
        partial.updateVoice("I want to")
        let emptyIntent = IntentSelection(goal: nil, task: nil)
        try expect(partialOrder.accept(sequence: 1, selection: emptyIntent, requestedPrevious: emptyIntent,
            current: emptyIntent, requestedConversation: partial, currentConversation: partial,
            requestedUtterance: partial.text, currentUtterance: partial.text), "Uninterpretable partial could not abstain")
        partial.updateVoice("I want to clear cookies")
        let emerging = IntentSelection(goal: partial.text, task: partial.text)
        try expect(partialOrder.accept(sequence: 2, selection: emerging, requestedPrevious: emptyIntent,
            current: emptyIntent, requestedConversation: partial, currentConversation: partial,
            requestedUtterance: partial.text, currentUtterance: partial.text), "Initial abstention retired the prefix of an emerging request")
        var intentSource = SessionTranscript()
        let task = "Clear the cookies."
        let generic = "Where do I click?"
        var utterance = task + " " + generic
        intentSource.appendTyped(utterance)
        var intent = IntentSelection(goal: nil, task: nil)
        func applyIntent(_ sequence: UInt64, _ value: IntentSelection) -> Bool {
            guard intentOrder.accept(sequence: sequence, selection: value,
                requestedPrevious: intent, current: intent, requestedConversation: intentSource,
                currentConversation: intentSource, requestedUtterance: utterance, currentUtterance: utterance) else { return false }
            intent = value
            return true
        }
        try expect(applyIntent(1, IntentSelection(goal: generic, task: task)), "Paired selection lost concrete task")
        try expect(applyIntent(2, IntentSelection(goal: task, task: task)), "Earlier task in the same utterance could not recover from generic focus")
        utterance = "Select cookies"
        intentSource.appendTyped(utterance)
        let stepIntent = IntentSelection(goal: utterance, task: task)
        try expect(applyIntent(3, stepIntent), "Concrete step discarded the broader task")
        let oldIntentSource = intentSource
        utterance = "Join my meeting"
        intentSource.appendTyped(utterance)
        let meeting = IntentSelection(goal: utterance, task: utterance)
        try expect(applyIntent(5, meeting), "New task could not replace both anchors")
        try expect(!intentOrder.accept(sequence: 4, selection: stepIntent, requestedPrevious: stepIntent,
            current: intent, requestedConversation: oldIntentSource, currentConversation: intentSource,
            requestedUtterance: "Select cookies", currentUtterance: utterance), "Old parallel response restored prior task")
        utterance = "Cancel that"
        intentSource.appendTyped(utterance)
        try expect(applyIntent(6, IntentSelection(goal: nil, task: nil)), "Cancellation did not clear both anchors")
        try expect(!applyIntent(7, meeting), "Cancelled source revived")
        try expect(!applyIntent(8, IntentSelection(goal: nil, task: "Select cookies")), "An older substep revived as a task after cancellation")
        utterance = "Join my meeting"
        intentSource.appendTyped(utterance)
        try expect(applyIntent(9, meeting), "Repeated request after cancellation did not use its new occurrence")
        let beforeRevision = intentSource
        intentSource.appendTyped("Open Calendar")
        try expect(!intentOrder.accept(sequence: 10, selection: meeting, requestedPrevious: meeting,
            current: meeting, requestedConversation: beforeRevision, currentConversation: intentSource,
            requestedUtterance: "Join my meeting", currentUtterance: "Open Calendar"), "Unseen speech accepted an older intent")

        let focus = ConversationFocus(transcript: "Find the old photo\nAttach the report", selectedGoal: "Find the old photo",
                                      currentUtterance: "Attach the report")
        try expect(focus.currentRequest == "Attach the report" && focus.earlierConversation == "Find the old photo",
                   "Hearing you waited for goal inference before advancing")
    }
}

#if !JEV_ASSIST_STANDALONE_TESTS
final class GoalFocusTests: XCTestCase {
    func testSpeechAndGoalProvenance() throws {
        try GoalFocusChecks.run { XCTAssertTrue($0, $1) }
    }
}
#endif
