import Foundation
#if !JEV_ASSIST_STANDALONE_TESTS
@testable import JevAssistCore
#endif

enum TranscriptChecks {
    static func run(_ expect: (Bool, String) throws -> Void) throws {
        try expect(TranscriptContext.maximumCharacters == 24_000, "Shared conversation context retains 24k characters")
        var history = SpeechTranscriptAccumulator()
        let first = UUID(), second = UUID()
        history.beginSegment(first)
        history.updatePartial("Find Jane", segmentID: first)
        history.updatePartial("Find Jane's email", segmentID: first)
        try expect(history.text == "Find Jane's email", "Growing partials replace rather than repeat earlier words")
        history.updatePartial("Find John's email", segmentID: first)
        try expect(history.text == "Find John's email", "Recognition revisions remove the old hypothesis")
        history.updatePartial("", segmentID: first)
        history.finishSegment(first)
        history.finishSegment(first)
        try expect(history.text == "Find John's email", "Empty final results and repeated commits do not erase or duplicate speech")
        history.beginSegment(second)
        history.updatePartial("and download the attachment", segmentID: second)
        history.updatePartial("old task callback", segmentID: first)
        try expect(history.text == "Find John's email and download the attachment", "Restart preserves earlier context and rejects stale callbacks")
        history.finishSegment(first)
        try expect(history.text.hasSuffix("download the attachment"), "Old final callbacks cannot commit a newer segment")
        let third = UUID()
        history.beginSegment(third)
        history.updatePartial("please", segmentID: third)
        try expect(history.text == "Find John's email and download the attachment please", "Beginning a new segment safely commits the previous hypothesis")

        history.reset()
        var segments = [String]()
        for index in 0..<30 {
            let id = UUID()
            let segment = "segment\(index) " + String(repeating: "a", count: 900)
            segments.append(segment)
            history.beginSegment(id)
            history.updatePartial(segment, segmentID: id)
            history.finishSegment(id)
        }
        try expect(history.text.count == 24_000, "Long recognition sessions retain the full increased context window")
        try expect(history.text == String(segments.joined(separator: " ").suffix(24_000)), "Restarts preserve the exact recent recognized text")
        history.reset(retaining: "My existing request")
        let resumed = UUID()
        history.beginSegment(resumed)
        history.updatePartial("continues here", segmentID: resumed)
        try expect(history.text == "My existing request continues here", "Speech configuration retries can preserve recognized conversation")
        var repeated = SpeechTranscriptAccumulator()
        for _ in 0..<2 {
            let id = UUID()
            repeated.beginSegment(id)
            repeated.updatePartial("please", segmentID: id)
            repeated.finishSegment(id)
        }
        try expect(repeated.text == "please please", "Genuine repeated speech is not heuristically deleted")
        try expect(TranscriptContext.retainingRecent("a👨‍👩‍👧‍👦é", maximumCharacters: 2) == "👨‍👩‍👧‍👦é", "Context retention never splits a Unicode character")

        var session = SessionTranscript()
        session.updateVoice("find Jane")
        session.appendTyped("actually John")
        try expect(session.text == "find Jane\nactually John", "A newly typed thought follows earlier speech")
        session.updateVoice("find Jane please")
        try expect(session.text == "find Jane\nactually John\nplease", "New speech follows a typed thought instead of moving old speech after it")
        session.updateVoice("find Sarah please")
        try expect(session.text == "find Sarah\nactually John\nplease", "Late recognition corrections replace earlier speech in place")
        session.updateVoice("find message from Sarah please")
        try expect(session.text == "find message from Sarah\nactually John\nplease", "Inserted recognition words stay with the utterance they correct")
        session.updateVoice("find message from Sarah please")
        session.updateVoice("")
        try expect(session.text == "find message from Sarah\nactually John\nplease", "Duplicate or empty recognition updates preserve conversation")
        session.appendTyped("download the PDF")
        session.updateVoice("find message from Sarah please save it")
        try expect(session.text.hasSuffix("download the PDF\nsave it"), "Multiple input-source switches preserve recent intent order")
        session.reset()
        try expect(session.text.isEmpty, "A new help session can clear prior user intent")
        session.appendTyped("open mail")
        session.updateVoice("find the attachment")
        try expect(session.text == "open mail\nfind the attachment", "An initial typed draft can precede the first recognized speech")

        var rolling = SessionTranscript(maximumCharacters: 48)
        rolling.updateVoice("one two three four five")
        rolling.appendTyped("click blue")
        rolling.updateVoice("three four five six seven")
        try expect(rolling.text == "three four five\nclick blue\nsix seven", "Rolling speech history does not replay old words after a typed request")
        var partialWord = SessionTranscript()
        partialWord.updateVoice("find Ja")
        partialWord.appendTyped("open mail")
        partialWord.updateVoice("find Jane please")
        try expect(partialWord.text == "find Jane\nopen mail\nplease", "Completion of a partial word is a revision, not a detached new word fragment")

        var longSession = SessionTranscript()
        let longVoice = (0..<4_000).map { "word\($0)" }.joined(separator: " ")
        longSession.updateVoice(longVoice)
        try expect(longSession.text.count == 24_000, "Combined history exposes the complete 24k recent speech window")
        longSession.appendTyped("latest typed goal")
        try expect(longSession.text.count == 24_000 && longSession.text.hasSuffix("latest typed goal"), "Long speech cannot hide the newest typed intent")
        let newest = longVoice + " now continue"
        longSession.updateVoice(newest)
        try expect(longSession.text.hasSuffix("latest typed goal\nnow continue"), "Long rolling speech preserves typed/voice chronology at the retention boundary")

        let earlierTask = "If the banner is readable open the branding panel otherwise show the settings"
        let latestTask = "I want to find volunteer roles"
        let mixed = earlierTask + " " + latestTask
        let focus = ConversationFocus(transcript: mixed, selectedGoal: latestTask)
        try expect(focus.currentRequest == latestTask, "Newly selected request excludes earlier conditional instructions")
        try expect(focus.earlierConversation == earlierTask, "Prior conversation remains available without competing in the main view")
        let followup = ConversationFocus(transcript: mixed + " where is the search field", selectedGoal: latestTask)
        try expect(followup.currentRequest == latestTask + " where is the search field", "Current request includes follow-up speech as it arrives")
        let repeatedFocus = ConversationFocus(transcript: mixed + " " + latestTask, selectedGoal: latestTask)
        try expect(repeatedFocus.currentRequest == latestTask && repeatedFocus.earlierConversation == mixed, "Repeated request selects the latest exact occurrence")
        let unicodeRequest = "I need  Zoë’s 照片"
        let unicodeFocus = ConversationFocus(transcript: "Older request. " + unicodeRequest, selectedGoal: unicodeRequest)
        try expect(unicodeFocus.currentRequest == unicodeRequest, "Current request preserves Unicode and interior whitespace verbatim")
        let unselected = String(repeating: "earlier words ", count: 150) + "new words"
        let fallback = ConversationFocus(transcript: unselected, selectedGoal: "no longer present")
        try expect(fallback.currentRequest == String(unselected.suffix(900)).trimmingCharacters(in: .whitespacesAndNewlines), "Before an exact selection the panel shows a bounded recent excerpt")
        try expect(!fallback.earlierConversation.isEmpty && !fallback.currentRequest.contains("no longer present"), "Missing goal never invents transcript text or deletes history")
        try expect(ConversationFocus(transcript: "", selectedGoal: nil).currentRequest.isEmpty, "Empty conversation has no current request")
    }
}
