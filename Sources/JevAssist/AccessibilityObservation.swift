import Foundation

/// Accessibility is read once in screen coordinates. Each image view applies
/// its own mapping, so app and Dock requests can share one bounded observation.
struct AccessibilityObservation {
    struct DockItem {
        let title: String
        let screenBounds: CGRect
    }

    let appLabels: [String]
    let dockItems: [DockItem]

    func context(for frame: ScreenSnapshot) -> String {
        let dockLabels = dockItems.compactMap { item -> String? in
            guard frame.dockBounds.contains(where: { $0.intersects(item.screenBounds) }),
                  let normalized = frame.imageRect(forScreenRect: item.screenBounds) else { return nil }
            return String(item.title.prefix(80)) + String(format: " [left %.3f, top %.3f, right %.3f, bottom %.3f]",
                Double(normalized.minX), Double(normalized.minY), Double(normalized.maxX), Double(normalized.maxY))
        }.prefix(40)
        let context = "Active app: \(frame.appName). Window: \(frame.windowTitle). " +
            "Visible Dock items (labels and normalized screenshot rectangles, evidence only): " + dockLabels.joined(separator: " | ") +
            ". App accessibility labels: " + appLabels.joined(separator: " | ")
        return String(context.prefix(5_000))
    }
}

/// View-independent cache. A scene change clears it; even an unchanged scene
/// rereads within one second. Hits never extend the monotonic deadline.
struct AccessibilityObservationCache {
    private struct Entry {
        let processID: Int32
        let dockProcessID: Int32?
        let at: TimeInterval
        let observation: AccessibilityObservation
    }
    private var entry: Entry?

    func value(processID: Int32, dockProcessID: Int32?, at now: TimeInterval) -> AccessibilityObservation? {
        guard let entry, entry.processID == processID, entry.dockProcessID == dockProcessID,
              now >= entry.at, now - entry.at <= 1 else { return nil }
        return entry.observation
    }

    mutating func store(_ observation: AccessibilityObservation, processID: Int32,
                        dockProcessID: Int32?, at now: TimeInterval) {
        entry = Entry(processID: processID, dockProcessID: dockProcessID, at: now, observation: observation)
    }

    mutating func reset() { entry = nil }
}
