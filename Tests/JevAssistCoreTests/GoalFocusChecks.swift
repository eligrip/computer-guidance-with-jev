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
