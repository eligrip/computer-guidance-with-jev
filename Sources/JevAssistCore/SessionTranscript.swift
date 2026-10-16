import Foundation

/// Interleaves typed thoughts with a revisable cumulative speech transcript.
/// Existing spoken words keep their place when recognition corrects them; newly
/// appended speech follows any typed thought received in the meantime.
public struct SessionTranscript: Sendable {
    private struct Word: Sendable {
        let id: UInt64
        let text: String
    }
    private enum Entry: Sendable {
        case voice(UInt64)
        case typed(String)
    }
    public let maximumCharacters: Int
    private var voiceWords: [Word] = []
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0

    public init(maximumCharacters: Int = TranscriptContext.maximumCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public var text: String {
        TranscriptContext.retainingRecent(rendered(), maximumCharacters: maximumCharacters)
    }

    public mutating func reset() {
        voiceWords = []
        entries = []
        nextID = 0
    }

    public mutating func appendTyped(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.append(.typed(TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)))
        trimStorage()
    }

    public mutating func updateVoice(_ fullTranscript: String) {
        let incoming = TranscriptContext.retainingRecent(fullTranscript, maximumCharacters: maximumCharacters)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let previous = voiceWords.map(\.text)
        guard incoming != previous else { return }
        // Empty recognizer events aren't an instruction to delete conversation.
        // A new session explicitly calls reset().
        guard !incoming.isEmpty else { return }
        let difference = incoming.difference(from: previous)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let keptOld = previous.indices.filter { !removed.contains($0) }
        let keptNew = incoming.indices.filter { !inserted.contains($0) }
        let anchors = Array(zip(keptOld, keptNew))
        var updated = [Word?](repeating: nil, count: incoming.count)
        var beforeAnchor: [UInt64: [UInt64]] = [:]
        var appendAtEnd: [UInt64] = []
        var priorOld = -1, priorNew = -1
        for (oldIndex, newIndex) in anchors + [(previous.count, incoming.count)] {
            let oldGap = Array((priorOld + 1)..<oldIndex)
            let newGap = Array((priorNew + 1)..<newIndex)
            for (offset, index) in newGap.enumerated() {
                if offset < oldGap.count {
                    // Corrected words replace earlier slots, even if a typed
                    // thought has arrived since that hypothesis was displayed.
                    updated[index] = Word(id: voiceWords[oldGap[offset]].id, text: incoming[index])
                } else {
                    nextID &+= 1
                    updated[index] = Word(id: nextID, text: incoming[index])
                    if oldIndex < previous.count {
                        // A recognizer inserted a word inside earlier speech.
                        beforeAnchor[voiceWords[oldIndex].id, default: []].append(nextID)
                    } else {
                        appendAtEnd.append(nextID)
                    }
                }
            }
            if oldIndex < previous.count {
                updated[newIndex] = Word(id: voiceWords[oldIndex].id, text: incoming[newIndex])
            }
            priorOld = oldIndex
            priorNew = newIndex
        }
        voiceWords = updated.compactMap { $0 }
        let liveIDs = Set(voiceWords.map(\.id))
        var timeline = [Entry]()
        for entry in entries {
            switch entry {
            case .voice(let id):
                if let additions = beforeAnchor.removeValue(forKey: id) { timeline.append(contentsOf: additions.map(Entry.voice)) }
                if liveIDs.contains(id) { timeline.append(entry) }
            case .typed: timeline.append(entry)
            }
        }
        // Anchors pruned by the bounded-history window stay pruned; old speech
        // must not jump after a more recent typed request when recognition rolls.
        timeline.append(contentsOf: appendAtEnd.map(Entry.voice))
        entries = timeline
        trimStorage()
    }

    private func rendered() -> String {
        let words = Dictionary(uniqueKeysWithValues: voiceWords.map { ($0.id, $0.text) })
        var blocks = [String](), spoken = [String]()
        for entry in entries {
            switch entry {
            case .voice(let id):
                if let word = words[id] { spoken.append(word) }
            case .typed(let text):
                if !spoken.isEmpty { blocks.append(spoken.joined(separator: " ")); spoken = [] }
                blocks.append(text)
            }
        }
        if !spoken.isEmpty { blocks.append(spoken.joined(separator: " ")) }
        return blocks.joined(separator: "\n")
    }

    private mutating func trimStorage() {
        // Keep a little extra for revisions around the visible boundary, while
        // text exposed to the app never exceeds maximumCharacters.
        let words = Dictionary(uniqueKeysWithValues: voiceWords.map { ($0.id, $0.text.count + 1) })
        let costs = entries.map { entry -> Int in
            switch entry {
            case .voice(let id): return words[id] ?? 0
            case .typed(let text): return text.count + 1
            }
        }
        var total = costs.reduce(0, +), removeCount = 0
        while total > maximumCharacters * 2, removeCount < entries.count - 1 {
            total -= costs[removeCount]
            removeCount += 1
        }
        if removeCount > 0 { entries.removeFirst(removeCount) }
    }
}
