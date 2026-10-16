import Foundation

/// Identity of the last exact occurrence in retained conversation. The text and
/// source slots both participate: correcting a command is not the same command,
/// and saying identical words later is not the same occurrence.
public struct TranscriptSourceIdentity: Equatable, Sendable {
    fileprivate struct Piece: Equatable, Sendable {
        let id: UInt64
        let lower: Int
        let upper: Int
    }
    fileprivate let epoch: UUID
    fileprivate let passage: String
    fileprivate let pieces: [Piece]
}

/// Interleaves typed thoughts with a revisable cumulative speech transcript.
/// Existing spoken words keep their place when recognition corrects them; newly
/// appended speech follows any typed thought received in the meantime.
public struct SessionTranscript: Sendable {
    private struct Word: Sendable {
        let id: UInt64
        let text: String
        let startsUtterance: Bool
    }
    private enum Entry: Sendable {
        case voice(UInt64)
        case typed(UInt64, String)
    }
    private struct RenderedSource {
        let id: UInt64
        let lower: Int
        let upper: Int
    }
    public let maximumCharacters: Int
    private var voiceWords: [Word] = []
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0
    private var sourceEpoch = UUID()

    public init(maximumCharacters: Int = TranscriptContext.maximumCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public var text: String {
        TranscriptContext.retainingRecent(rendered().text, maximumCharacters: maximumCharacters)
    }

    public func sourceIdentity(of passage: String) -> TranscriptSourceIdentity? {
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let rendered = rendered()
        let retained = TranscriptContext.retainingRecent(rendered.text, maximumCharacters: maximumCharacters)
        guard let match = retained.range(of: passage, options: .backwards) else { return nil }
        let dropped = rendered.text.count - retained.count
        let lower = dropped + retained.distance(from: retained.startIndex, to: match.lowerBound)
        let upper = dropped + retained.distance(from: retained.startIndex, to: match.upperBound)
        let pieces = Self.sourcePieces(in: lower..<upper, sources: rendered.sources)
        guard !pieces.isEmpty else { return nil }
        return TranscriptSourceIdentity(epoch: sourceEpoch, passage: passage, pieces: pieces)
    }

    /// Returns the retained character offset of this occurrence, even when a
    /// later identical phrase exists. Corrections elsewhere do not move its ID.
    public func sourceOffset(of identity: TranscriptSourceIdentity) -> Int? {
        guard identity.epoch == sourceEpoch else { return nil }
        let rendered = rendered()
        let retained = TranscriptContext.retainingRecent(rendered.text, maximumCharacters: maximumCharacters)
        let dropped = rendered.text.count - retained.count
        var searchStart = retained.startIndex
        while searchStart < retained.endIndex,
              let match = retained.range(of: identity.passage, range: searchStart..<retained.endIndex) {
            let lower = retained.distance(from: retained.startIndex, to: match.lowerBound)
            let upper = retained.distance(from: retained.startIndex, to: match.upperBound)
            if Self.sourcePieces(in: (lower + dropped)..<(upper + dropped), sources: rendered.sources) == identity.pieces {
                return lower
            }
            searchStart = retained.index(after: match.lowerBound)
        }
        return nil
    }

    private static func sourcePieces(in range: Range<Int>, sources: [RenderedSource]) -> [TranscriptSourceIdentity.Piece] {
        sources.compactMap { source -> TranscriptSourceIdentity.Piece? in
            let start = max(range.lowerBound, source.lower), end = min(range.upperBound, source.upper)
            guard start < end else { return nil }
            return TranscriptSourceIdentity.Piece(id: source.id, lower: start - source.lower, upper: end - source.lower)
        }
    }

    public mutating func reset() {
        voiceWords = []
        entries = []
        nextID = 0
        sourceEpoch = UUID()
    }

    public mutating func appendTyped(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        nextID &+= 1
        entries.append(.typed(nextID, TranscriptContext.retainingRecent(text, maximumCharacters: maximumCharacters)))
        trimStorage()
    }

    public mutating func updateVoice(_ fullTranscript: String) {
        let bounded = TranscriptContext.retainingRecent(fullTranscript, maximumCharacters: maximumCharacters)
        var incoming = [String](), startsUtterance = [Bool]()
        for line in bounded.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            for (index, word) in words.enumerated() {
                startsUtterance.append(index == 0 && !incoming.isEmpty)
                incoming.append(word)
            }
        }
        let previous = voiceWords.map(\.text)
        guard incoming != previous || startsUtterance != voiceWords.map(\.startsUtterance) else { return }
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
                    updated[index] = Word(id: voiceWords[oldGap[offset]].id, text: incoming[index], startsUtterance: startsUtterance[index])
                } else {
                    nextID &+= 1
                    updated[index] = Word(id: nextID, text: incoming[index], startsUtterance: startsUtterance[index])
                    if oldIndex < previous.count {
                        // A recognizer inserted a word inside earlier speech.
                        beforeAnchor[voiceWords[oldIndex].id, default: []].append(nextID)
                    } else {
                        appendAtEnd.append(nextID)
                    }
                }
            }
            if oldIndex < previous.count {
                updated[newIndex] = Word(id: voiceWords[oldIndex].id, text: incoming[newIndex], startsUtterance: startsUtterance[newIndex])
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

    private func rendered() -> (text: String, sources: [RenderedSource]) {
        let words = Dictionary(uniqueKeysWithValues: voiceWords.map { ($0.id, $0) })
        var text = "", sources = [RenderedSource](), length = 0
        var previousWasVoice = false
        for entry in entries {
            let id: UInt64, value: String, separator: String
            switch entry {
            case .voice(let wordID):
                guard let word = words[wordID] else { continue }
                id = wordID
                value = word.text
                separator = previousWasVoice && !word.startsUtterance ? " " : "\n"
                previousWasVoice = true
            case .typed(let entryID, let typed):
                id = entryID
                value = typed
                separator = "\n"
                previousWasVoice = false
            }
            if !text.isEmpty { text += separator; length += separator.count }
            let start = length
            text += value
            length += value.count
            sources.append(RenderedSource(id: id, lower: start, upper: length))
        }
        return (text, sources)
    }

    private mutating func trimStorage() {
        // Keep a little extra for revisions around the visible boundary, while
        // text exposed to the app never exceeds maximumCharacters.
        let words = Dictionary(uniqueKeysWithValues: voiceWords.map { ($0.id, $0.text.count + 1) })
        let costs = entries.map { entry -> Int in
            switch entry {
            case .voice(let id): return words[id] ?? 0
            case .typed(_, let text): return text.count + 1
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
