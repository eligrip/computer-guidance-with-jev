import Foundation

public enum GuidancePace: String, CaseIterable, Identifiable, Sendable {
    case fast, balanced
    public var id: String { rawValue }
    public var title: String { self == .fast ? "Fast" : "Balanced" }
    public var maximumConcurrentRequests: Int { self == .fast ? 2 : 1 }
    public var minimumInterval: TimeInterval { self == .fast ? 0.1 : 0.25 }
    public var observationInterval: UInt64 { self == .fast ? 80_000_000 : 160_000_000 }
    public static func restored(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .fast }

    public func canDispatch(inFlight: Int, lastDispatch: Date, retryAfter: Date, now: Date,
                            sampling: BoxSampling = .single) -> Bool {
        inFlight < sampling.maximumConcurrentBatches(pace: self) && now >= retryAfter
            && now.timeIntervalSince(lastDispatch) >= minimumInterval
    }
}
