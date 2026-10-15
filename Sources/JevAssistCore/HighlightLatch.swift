import Foundation

public struct GuidanceTicket: Equatable, Sendable {
    public let sessionEpoch: UInt64
    public let screenGeneration: UInt64
    public let sequence: UInt64
}

/// Pure state machine; isolate it on the UI actor when used by the application.
/// Only a meaningful screen change or explicit session boundary releases a box.
/// A click, transcript revision, new goal, elapsed time, or network error does not.
public struct HighlightLatch: Sendable {
    public private(set) var box: NormalizedBox?
    public private(set) var sessionEpoch: UInt64 = 0
    public private(set) var screenGeneration: UInt64 = 0
    public private(set) var isActive = false
    private var nextSequence: UInt64 = 0
    private var lastCompletedSequence: UInt64 = 0

    public init() {}

    public mutating func beginSession() {
        sessionEpoch &+= 1
        screenGeneration = 0
        nextSequence = 0
        lastCompletedSequence = 0
        box = nil
        isActive = true
    }

    public mutating func endSession() {
        sessionEpoch &+= 1
        box = nil
        isActive = false
    }

    /// Call only after comparing captured screen content, never on a click alone.
    public mutating func screenDidChange() {
        guard isActive else { return }
        screenGeneration &+= 1
        box = nil
    }

    public mutating func makeRequest() -> GuidanceTicket? {
        guard isActive else { return nil }
        nextSequence &+= 1
        return GuidanceTicket(sessionEpoch: sessionEpoch, screenGeneration: screenGeneration,
                              sequence: nextSequence)
    }

    /// Returns true only when a new box is actually latched. Later evaluations
    /// may continue, but cannot move or remove this box on the same screen.
    @discardableResult
    public mutating func apply(_ result: GuidanceResult, for ticket: GuidanceTicket) -> Bool {
        guard isActive, ticket.sessionEpoch == sessionEpoch,
              ticket.screenGeneration == screenGeneration,
              ticket.sequence > lastCompletedSequence,
              ticket.sequence <= nextSequence else { return false }
        lastCompletedSequence = ticket.sequence
        guard box == nil, let candidate = result.box, candidate.isValid,
              result.confidence.isFinite, (0...1).contains(result.confidence),
              result.presence.isFinite, (0...1).contains(result.presence) else { return false }
        box = candidate
        return true
    }
}
