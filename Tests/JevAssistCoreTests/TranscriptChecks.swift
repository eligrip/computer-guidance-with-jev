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
        try expect(history.text == "Find John's email\nand download the attachment", "Restart preserves earlier context and rejects stale callbacks")
        history.finishSegment(first)
        try expect(history.text.hasSuffix("download the attachment"), "Old final callbacks cannot commit a newer segment")
        let third = UUID()
        history.beginSegment(third)
        history.updatePartial("please", segmentID: third)
        try expect(history.text == "Find John's email\nand download the attachment\nplease", "Beginning a new segment safely commits the previous hypothesis")

        var timed = SpeechTranscriptAccumulator()
        let timedID = UUID()
        let earlyAudio = SpeechTranscriptAudioRange(start: 1, end: 3)!
        let laterAudio = SpeechTranscriptAudioRange(start: 8, end: 10)!
        timed.beginSegment(timedID)
        timed.updatePartial("open the wrong app", segmentID: timedID, audioRange: earlyAudio)
        timed.updatePartial("open mail", segmentID: timedID, audioRange: SpeechTranscriptAudioRange(start: 1.1, end: 2.8))
        try expect(timed.text == "open mail", "Shorter overlapping audio is a correction, not a new utterance")
        try expect(!timed.updatePartial("open mail", segmentID: timedID, audioRange: earlyAudio), "A repeated result for the same audio does not duplicate or reemit text")
        timed.updatePartial("find the attachment", segmentID: timedID, audioRange: laterAudio)
        try expect(timed.text == "open mail\nfind the attachment", "Later disjoint audio preserves the preceding utterance within the same recognition task")
        timed.updatePartial("save the attachment", segmentID: timedID, audioRange: laterAudio)
        try expect(timed.text == "open mail\nsave the attachment", "Corrections after a rollover replace only that utterance")
        timed.updatePartial("open email", segmentID: timedID, audioRange: earlyAudio)
        try expect(timed.text == "open email\nsave the attachment", "A correction of earlier audio cannot erase later recognized speech")
        timed.updatePartial("open email and save the attachment", segmentID: timedID,
                            audioRange: SpeechTranscriptAudioRange(start: 1, end: 10))
        try expect(timed.text == "open email and save the attachment", "A later cumulative result replaces overlapping utterances without duplication")
        timed.updatePartial("please", segmentID: timedID, audioRange: SpeechTranscriptAudioRange(start: 10, end: 11))
        try expect(timed.text == "open email and save the attachment\nplease", "Adjacent nonoverlapping audio ranges remain separate")
        timed.updatePartial("", segmentID: timedID, audioRange: laterAudio)
        timed.finishSegment(timedID)
        timed.finishSegment(timedID)
        try expect(timed.text == "open email and save the attachment\nplease", "Finishing a timed request commits every utterance exactly once")
        let restartedID = UUID()
        timed.beginSegment(restartedID)
        timed.updatePartial("now open notes", segmentID: restartedID, audioRange: earlyAudio)
        try expect(timed.text.hasSuffix("please\nnow open notes"), "Audio timestamps restart per request without replacing committed conversation")
        timed.updatePartial("stale", segmentID: timedID, audioRange: earlyAudio)
        try expect(timed.text.hasSuffix("please\nnow open notes"), "Stale timed callbacks cannot change a restarted request")

        var ambiguous = SpeechTranscriptAccumulator()
        let ambiguousID = UUID()
        ambiguous.beginSegment(ambiguousID)
        ambiguous.updatePartial("a long incorrect hypothesis", segmentID: ambiguousID)
        ambiguous.updatePartial("a correction", segmentID: ambiguousID)
        try expect(ambiguous.text == "a correction", "Short untimed results are never heuristically appended")
        ambiguous.updatePartial("first request", segmentID: ambiguousID, audioRange: earlyAudio)
        ambiguous.updatePartial("next request", segmentID: ambiguousID)
        ambiguous.updatePartial("next request", segmentID: ambiguousID, audioRange: laterAudio)
        try expect(ambiguous.text == "first request\nnext request", "Later valid timing recovers earlier evidence despite an intermediate untimed result")
        try expect(SpeechTranscriptAudioRange(start: 0, end: 0) == nil &&
                   SpeechTranscriptAudioRange(start: -1, end: 3) == nil &&
                   SpeechTranscriptAudioRange(start: 0, end: .infinity) == nil &&
                   SpeechTranscriptAudioRange(start: .nan, end: 3) == nil,
                   "Unavailable or invalid timing cannot establish an utterance boundary")
        let unfinished = [SpeechTranscriptSegmentTiming(start: 8, duration: 0.5),
                          SpeechTranscriptSegmentTiming(start: 8.5, duration: 0)]
        try expect(SpeechTranscriptAudioRange.covering(unfinished) == SpeechTranscriptAudioRange(start: 8, end: 8.5),
                   "An unfinished final word keeps the known timing of preceding words")
        try expect(SpeechTranscriptAudioRange.covering([.init(start: 0, duration: 0)]) == nil &&
                   SpeechTranscriptAudioRange.covering([.init(start: 1, duration: -1)]) == nil &&
                   SpeechTranscriptAudioRange.covering([.init(start: 3, duration: 1), .init(start: 1, duration: 1)]) == nil &&
                   SpeechTranscriptAudioRange.covering([]) == nil,
                   "Entirely provisional, invalid, reversed or absent segment timings do not imply a boundary")
        var focusedSpeech = SpeechTranscriptAccumulator()
        focusedSpeech.beginSegment(ambiguousID)
        focusedSpeech.updatePartial("open mail", segmentID: ambiguousID, audioRange: earlyAudio)
        focusedSpeech.updatePartial("save att", segmentID: ambiguousID, audioRange: .covering(unfinished))
        try expect(focusedSpeech.text == "open mail\nsave att" && focusedSpeech.currentUtterance == "save att",
                   "A partially timed new utterance preserves history and immediately supplies its exact focus")
        focusedSpeech.updatePartial("save attachment", segmentID: ambiguousID, audioRange: laterAudio)
        try expect(focusedSpeech.text == "open mail\nsave attachment" && focusedSpeech.currentUtterance == "save attachment",
                   "Completion of an unfinished word revises its utterance without duplication")
        focusedSpeech.updatePartial("open email", segmentID: ambiguousID, audioRange: earlyAudio)
        try expect(focusedSpeech.currentUtterance == "save attachment",
                   "An earlier audio correction cannot take focus away from the latest utterance")
        focusedSpeech.finishSegment(ambiguousID)
        try expect(focusedSpeech.currentUtterance == "save attachment", "Finalization preserves the last exact utterance")
        try expect(SpeechTranscriptUpdate(text: "open mail", currentUtterance: "open settings").currentUtterance == nil &&
                   SpeechTranscriptUpdate(text: "open mail", currentUtterance: "").currentUtterance == nil &&
                   SpeechTranscriptUpdate(text: "open mail then settings", currentUtterance: "open mail").currentUtterance == nil,
                   "An utterance must be a nonempty exact source suffix")
        let retainedFocus = SpeechTranscriptUpdate(text: "older\nfind Zoë’s 照片", currentUtterance: "find Zoë’s 照片")
        try expect(retainedFocus.currentUtterance == "find Zoë’s 照片", "Exact focus preserves punctuation and Unicode")
        let cumulative = "Open mail. Now find Zoë’s 照片."
        let cumulativeNS = cumulative as NSString
        let pauseSegments: [SpeechTranscriptSegmentTiming] = [
            .init(start: 1, duration: 0.3, sourceRange: cumulativeNS.range(of: "Open")),
            .init(start: 1.4, duration: 0.4, sourceRange: cumulativeNS.range(of: "mail")),
            .init(start: 3, duration: 0.2, sourceRange: cumulativeNS.range(of: "Now")),
            .init(start: 3.3, duration: 0, sourceRange: cumulativeNS.range(of: "find"))
        ]
        let pauseFocus = SpeechTranscriptFocus.currentUtterance(in: cumulative, segments: pauseSegments)
        try expect(pauseFocus == "Now find Zoë’s 照片.", "A measured audio pause focuses the exact latest suffix of a cumulative hypothesis")
        var cumulativeSpeech = SpeechTranscriptAccumulator()
        cumulativeSpeech.beginSegment(ambiguousID)
        cumulativeSpeech.updatePartial(cumulative, segmentID: ambiguousID, audioRange: .covering(pauseSegments), currentUtterance: pauseFocus)
        try expect(cumulativeSpeech.text == cumulative && cumulativeSpeech.currentUtterance == pauseFocus,
                   "Audio focus leaves the complete recognized history available")
        try expect(SpeechTranscriptFocus.currentUtterance(in: cumulative, segments: [.init(start: 0, duration: 0)]) == cumulative &&
                   SpeechTranscriptFocus.currentUtterance(in: cumulative, segments: [.init(start: 0, duration: 1), .init(start: 5, duration: 0)]) == cumulative,
                   "Unavailable timing or missing source ranges cannot invent a text boundary")
        try expect(SpeechTranscriptFocus.currentUtterance(in: cumulative, segments: [
            .init(start: 0, duration: 0.5, sourceRange: cumulativeNS.range(of: "Open")),
            .init(start: 0.6, duration: 0.5, sourceRange: cumulativeNS.range(of: "mail"))]) == cumulative,
                   "Continuous speech keeps its full hypothesis rather than an arbitrary trailing word window")
        var cappedFocus = SpeechTranscriptAccumulator(maximumCharacters: 12)
        cappedFocus.beginSegment(ambiguousID)
        cappedFocus.updatePartial("old context\nopen mail", segmentID: ambiguousID, currentUtterance: "open mail")
        try expect(cappedFocus.currentUtterance == "open mail" && cappedFocus.text.hasSuffix("open mail"),
                   "A retained current utterance survives context truncation")
        cappedFocus.updatePartial("a much longer utterance", segmentID: ambiguousID, currentUtterance: "a much longer utterance")
        try expect(cappedFocus.currentUtterance == nil, "Truncated-away focus is rejected instead of pretending it remains verbatim")
        var repeatedAudio = SpeechTranscriptAccumulator()
        repeatedAudio.beginSegment(ambiguousID)
        repeatedAudio.updatePartial("please", segmentID: ambiguousID, audioRange: earlyAudio)
        repeatedAudio.updatePartial("please", segmentID: ambiguousID, audioRange: laterAudio)
        try expect(repeatedAudio.text == "please\nplease", "Identical words in distinct audio are genuine repeated speech")
        var longTimed = SpeechTranscriptAccumulator()
        longTimed.beginSegment(ambiguousID)
        let firstLong = String(repeating: "a", count: 20_000), secondLong = String(repeating: "b", count: 20_000)
        longTimed.updatePartial(firstLong, segmentID: ambiguousID, audioRange: earlyAudio)
        longTimed.updatePartial(secondLong, segmentID: ambiguousID, audioRange: laterAudio)
        try expect(longTimed.text == String((firstLong + "\n" + secondLong).suffix(24_000)), "Timing-aware retention keeps the exact complete recent 24k window")
        var timedConversation = SessionTranscript()
        var mixedAudio = SpeechTranscriptAccumulator()
        mixedAudio.beginSegment(ambiguousID)
        mixedAudio.updatePartial("open mail", segmentID: ambiguousID, audioRange: earlyAudio)
        timedConversation.updateVoice(mixedAudio.text)
        timedConversation.appendTyped("choose the latest message")
        mixedAudio.updatePartial("save the attachment", segmentID: ambiguousID, audioRange: laterAudio)
        timedConversation.updateVoice(mixedAudio.text)
        try expect(timedConversation.text == "open mail\nchoose the latest message\nsave the attachment", "Preserved earlier utterances do not override a newer typed thought or the latest spoken request")

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
        try expect(history.text == String(segments.joined(separator: "\n").suffix(24_000)), "Restarts preserve the exact recent recognized text")
        history.reset(retaining: "My existing request")
        let resumed = UUID()
        history.beginSegment(resumed)
        history.updatePartial("continues here", segmentID: resumed)
        try expect(history.text == "My existing request\ncontinues here", "Speech configuration retries can preserve recognized conversation")
        var repeated = SpeechTranscriptAccumulator()
        for _ in 0..<2 {
            let id = UUID()
            repeated.beginSegment(id)
            repeated.updatePartial("please", segmentID: id)
            repeated.finishSegment(id)
        }
        try expect(repeated.text == "please\nplease", "Genuine repeated speech is not heuristically deleted")
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

        var boundaries = SessionTranscript()
        boundaries.updateVoice("open mail find attachment")
        boundaries.updateVoice("open mail\nfind attachment")
        try expect(boundaries.text == "open mail\nfind attachment", "Boundary-only recognition changes preserve actual utterance separation")
        boundaries.updateVoice("open email\nfind attachment")
        try expect(boundaries.text == "open email\nfind attachment", "Corrections preserve utterance boundaries")
        var identity = SessionTranscript()
        identity.updateVoice("open male\nfind the attachment")
        let originalIdentity = identity.sourceIdentity(of: "find the attachment")
        try expect(originalIdentity != nil, "A source identity locates an exact retained command")
        identity.updateVoice("open mail\nfind the attachment")
        try expect(identity.sourceIdentity(of: "find the attachment") == originalIdentity,
                   "Correcting earlier speech preserves the current command's source identity")
        identity.updateVoice("open the mail app\nfind the attachment")
        try expect(identity.sourceIdentity(of: "find the attachment") == originalIdentity,
                   "Inserting earlier words preserves the current command's source identity")
        identity.updateVoice("open the mail app\nfind the attachment\nfind the attachment")
        let repeatedIdentity = identity.sourceIdentity(of: "find the attachment")
        try expect(repeatedIdentity != nil && repeatedIdentity != originalIdentity,
                   "A deliberate repeated spoken command has a new source occurrence")
        try expect(identity.sourceOffset(of: originalIdentity!) == "open the mail app\n".count &&
                   identity.sourceOffset(of: repeatedIdentity!) == "open the mail app\nfind the attachment\n".count,
                   "Source offsets locate stored earlier occurrences rather than the newest equal phrase")
        identity.updateVoice("open the mail app\nfind the attachment\nsave the attachment")
        try expect(identity.sourceIdentity(of: "save the attachment") != repeatedIdentity,
                   "A correction of the command itself changes its source identity")
        try expect(identity.sourceOffset(of: repeatedIdentity!) == nil,
                   "A corrected command cannot be located under its old identity")
        identity.appendTyped("find the attachment")
        let typedIdentity = identity.sourceIdentity(of: "find the attachment")
        try expect(typedIdentity != originalIdentity && typedIdentity != repeatedIdentity,
                   "A later typed command is distinct from identical spoken text")
        identity.appendTyped("find the attachment")
        try expect(identity.sourceIdentity(of: "find the attachment") != typedIdentity,
                   "Repeated typed entries each keep a separate occurrence")
        let beforeReset = identity.sourceIdentity(of: "find the attachment")
        identity.reset()
        identity.appendTyped("find the attachment")
        try expect(identity.sourceIdentity(of: "find the attachment") != beforeReset,
                   "New sessions cannot reuse source identities")
        try expect(identity.sourceOffset(of: beforeReset!) == nil, "Source offsets reject a prior session's occurrence")
        try expect(identity.sourceIdentity(of: "absent command") == nil && identity.sourceIdentity(of: " ") == nil,
                   "Missing or whitespace-only passages have no source identity")
        var unicodeIdentity = SessionTranscript()
        unicodeIdentity.updateVoice("old 👨‍👩‍👧‍👦\nfind Zoë’s 照片")
        let unicodeSource = unicodeIdentity.sourceIdentity(of: "Zoë’s 照片")
        unicodeIdentity.updateVoice("a corrected 👨‍👩‍👧‍👦\nfind Zoë’s 照片")
        try expect(unicodeSource != nil && unicodeIdentity.sourceIdentity(of: "Zoë’s 照片") == unicodeSource,
                   "Source identities use character-safe offsets through Unicode corrections")
        var boundedIdentity = SessionTranscript(maximumCharacters: 50)
        boundedIdentity.updateVoice("one two three four five\nopen settings")
        let boundedSource = boundedIdentity.sourceIdentity(of: "open settings")
        boundedIdentity.updateVoice("three four five\nopen settings")
        boundedIdentity.appendTyped("choose audio")
        try expect(boundedSource != nil && boundedIdentity.sourceIdentity(of: "open settings") == boundedSource,
                   "Prefix truncation and later typed context preserve a retained command identity")
        try expect(boundedIdentity.sourceOffset(of: boundedSource!) == "three four five\n".count,
                   "Source offsets follow prefix removal using retained character coordinates")
        boundedIdentity.updateVoice("three four five\nopen preferences")
        try expect(boundedIdentity.sourceIdentity(of: "open settings") == nil,
                   "Corrected-away text cannot retain an identity")

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
