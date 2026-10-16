import Foundation

/// A reduced grayscale image and the geometry needed to map its answers back
/// to the screen. Identity must change when the app, window or mapping changes.
public struct ScreenSceneSample: Sendable {
    public let identity: String
    public let fingerprint: [UInt8]
    public let secondaryFingerprint: [UInt8]

    public init(identity: String, fingerprint: [UInt8], secondaryFingerprint: [UInt8] = []) {
        self.identity = identity
        self.fingerprint = fingerprint
        self.secondaryFingerprint = secondaryFingerprint
    }
}

/// Distinguishes content/layout changes from small appearance changes. It has
/// no highlight timeout: an unchanged scene can remain current indefinitely.
public struct ScreenSceneDetector: Sendable {
    public struct Observation: Equatable, Sendable {
        public let changed: Bool
        public let stable: Bool
    }

    private enum Difference: Int { case none, localized, broad }
    private var baseline: ScreenSceneSample?
    private var pending: ScreenSceneSample?
    private var pendingSince: TimeInterval = 0
    private let settlingInterval: TimeInterval
    private static let width = 128
    private static let height = 80

    public init(settlingInterval: TimeInterval = 0.12) {
        self.settlingInterval = max(0, settlingInterval)
    }

    public mutating func reset() {
        baseline = nil
        pending = nil
    }

    public static func sameScene(_ first: ScreenSceneSample, _ second: ScreenSceneSample) -> Bool {
        first.identity == second.identity && difference(first, second) == .none
    }

    /// `at` is a monotonic clock supplied by the caller, making fast sampling
    /// and elapsed-time behavior deterministic in tests.
    public mutating func observe(_ frame: ScreenSceneSample, at: TimeInterval) -> Observation {
        guard let baseline else { return accept(frame) }
        guard baseline.identity == frame.identity else { return accept(frame) }
        switch Self.difference(baseline, frame) {
        case .none:
            pending = nil
            return Observation(changed: false, stable: true)
        case .broad:
            // Navigation/scrolling must not leave an old target on new content.
            return accept(frame)
        case .localized:
            if let pending, Self.sameScene(pending, frame) {
                // Preserve the FIRST sample's deadline. Updating this timestamp
                // on every frame starves requests at high observation rates.
                if at - pendingSince >= settlingInterval { return accept(frame) }
            } else {
                pending = frame
                pendingSince = at
            }
            return Observation(changed: false, stable: false)
        }
    }

    private mutating func accept(_ frame: ScreenSceneSample) -> Observation {
        baseline = frame
        pending = nil
        return Observation(changed: true, stable: true)
    }

    private static func difference(_ first: ScreenSceneSample, _ second: ScreenSceneSample) -> Difference {
        let primary = pixelDifference(first.fingerprint, second.fingerprint, secondary: false)
        if primary == .broad { return primary }
        let secondary: Difference
        if first.secondaryFingerprint.isEmpty && second.secondaryFingerprint.isEmpty {
            secondary = .none
        } else {
            secondary = pixelDifference(first.secondaryFingerprint, second.secondaryFingerprint, secondary: true)
        }
        return primary.rawValue >= secondary.rawValue ? primary : secondary
    }

    private static func pixelDifference(_ a: [UInt8], _ b: [UInt8], secondary: Bool) -> Difference {
        let count = width * height
        guard a.count == count, b.count == count else { return .broad }
        var changed = 0
        var totalDifference = 0
        var edgeChanges = 0
        var tiles = [Int](repeating: 0, count: (width / 8) * (height / 8))
        for index in 0..<count {
            let delta = abs(Int(a[index]) - Int(b[index]))
            totalDifference += delta
            if delta > 24 {
                changed += 1
                tiles[(index / width / 8) * (width / 8) + index % width / 8] += 1
            }
            if index % width > 0 && index % width < width - 1 && index >= width && index < count - width,
               hasEdge(a, at: index) != hasEdge(b, at: index) {
                edgeChanges += 1
            }
        }
        let fraction = Double(changed) / Double(count)
        let mean = Double(totalDifference) / Double(count)
        // The independent Dock thumbnail magnifies tiny icon badges, bounces,
        // and hover effects. Require a larger share of that surface to change.
        if fraction >= (secondary ? 0.30 : 0.10), mean >= 3 { return .broad }
        let coherentTiles = tiles.filter { $0 >= 6 }
        let coherentPixels = coherentTiles.reduce(0, +)
        let minimumPixels = secondary ? 1_024 : 96
        let minimumEdges = secondary ? 150 : 40
        // A hover can recolor an existing control without moving its edges.
        // New dialogs, text and layout alter both pixels AND edge locations.
        // Requiring several coherent tiles also rejects isolated pixel noise.
        if coherentPixels >= minimumPixels, coherentTiles.count >= 3, edgeChanges >= minimumEdges {
            return .localized
        }
        return .none
    }

    private static func hasEdge(_ pixels: [UInt8], at index: Int) -> Bool {
        let value = Int(pixels[index])
        return abs(value - Int(pixels[index - 1])) > 24 ||
            abs(value - Int(pixels[index + 1])) > 24 ||
            abs(value - Int(pixels[index - width])) > 24 ||
            abs(value - Int(pixels[index + width])) > 24
    }
}
