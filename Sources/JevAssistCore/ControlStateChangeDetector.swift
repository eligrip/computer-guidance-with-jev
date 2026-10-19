import Foundation

/// Observed control state can change too little to survive a screen thumbnail
/// (for example a checkbox tick). Missing AX reads are uncertainty, not change.
public struct ControlStateChangeDetector: Sendable {
    private let baseline: String
    private var pending: String?
    private var pendingSince: TimeInterval = 0
    public init(baseline: String) { self.baseline = baseline }

    public mutating func observe(_ state: String?, at: TimeInterval) -> ScreenSceneDetector.Observation {
        guard let state else {
            pending = nil
            return .init(changed: false, stable: true)
        }
        guard state != baseline else {
            pending = nil
            return .init(changed: false, stable: true)
        }
        if pending != state { pending = state; pendingSince = at }
        return .init(changed: at - pendingSince >= 0.12, stable: false)
    }
}
