import Foundation

public enum BoxSampling: String, CaseIterable, Identifiable, Sendable {
    case single, consensus
    public var id: String { rawValue }
    public var title: String { self == .single ? "Single check" : "Three checks" }
    public var sampleCount: Int { self == .single ? 1 : 3 }
    public static func restored(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .single }

    public func maximumConcurrentBatches(pace: GuidancePace) -> Int {
        self == .consensus ? 1 : pace.maximumConcurrentRequests
    }
}

public struct BoxSample: Codable, Equatable, Sendable {
    public let box: NormalizedBox?
    public let confidence: Double
    public let presence: Double

    public init(box: NormalizedBox?, confidence: Double, presence: Double) {
        self.box = box; self.confidence = confidence; self.presence = presence
    }

    public var isValid: Bool {
        box?.isValid != false && confidence.isFinite && (0...1).contains(confidence)
            && presence.isFinite && (0...1).contains(presence)
    }
}

/// Evidence from one same-image batch. Rust owns selection and coordinate fusion.
public struct BoxEnsemble: Codable, Equatable, Sendable {
    public let samples: [BoxSample]
    public let selectedIndices: [Int]
    public let method: String
    public let iouThreshold: Double

    enum CodingKeys: String, CodingKey {
        case samples, method
        case selectedIndices = "selected_indices", iouThreshold = "iou_threshold"
    }

    public init(samples: [BoxSample], selectedIndices: [Int], method: String, iouThreshold: Double) {
        self.samples = samples; self.selectedIndices = selectedIndices
        self.method = method; self.iouThreshold = iouThreshold
    }

    public func isValid(for box: NormalizedBox?) -> Bool {
        guard samples.count == 3, samples.allSatisfy(\.isValid),
              iouThreshold.isFinite, (0...1).contains(iouThreshold),
              Set(selectedIndices).count == selectedIndices.count,
              selectedIndices.allSatisfy({ samples.indices.contains($0) && samples[$0].box != nil }) else { return false }
        switch method {
        case "weighted_agreement": return box != nil && (2...3).contains(selectedIndices.count)
        case "no_agreement", "insufficient_valid_samples": return box == nil && selectedIndices.isEmpty
        default: return false
        }
    }
}
