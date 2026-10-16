import Foundation

/// Edges measured from the top-left of the image, each in 0...1.
public struct NormalizedBox: Codable, Equatable, Sendable {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public var isValid: Bool {
        [top, bottom, left, right].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && top < bottom && left < right
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var isFinal: Bool
    public var timestamp: Date

    public init(id: UUID = UUID(), text: String, isFinal: Bool, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

/// The text is copied from speech; Jev selects it rather than composing a summary.
public struct GoalAnchor: Codable, Equatable, Sendable {
    public let text: String
    public let sourceIDs: [UUID]
    public let updatedAt: Date

    public init(text: String, sourceIDs: [UUID], updatedAt: Date = Date()) {
        self.text = text
        self.sourceIDs = sourceIDs
        self.updatedAt = updatedAt
    }
}

public struct GuidanceInput: Sendable {
    public let transcript: String
    public let currentUtterance: String?
    public let goal: String?
    public let notes: String
    public let browserContext: String?
    public let accessibilityContext: String?
    public let imageJPEG: Data
    public let sampling: BoxSampling

    /// The caller prepares an upright JPEG within TypeSafe's documented image limits.
    public init(transcript: String, goal: String?, notes: String, browserContext: String?,
                accessibilityContext: String?, imageJPEG: Data, sampling: BoxSampling = .single,
                currentUtterance: String? = nil) {
        self.transcript = transcript
        self.currentUtterance = currentUtterance
        self.goal = goal
        self.notes = notes
        self.browserContext = browserContext
        self.accessibilityContext = accessibilityContext
        self.imageJPEG = imageJPEG
        self.sampling = sampling
    }
}

public struct GuidanceResult: Equatable, Sendable {
    /// Nil means presence/confidence gating did not support showing a target.
    public let box: NormalizedBox?
    public let confidence: Double
    public let presence: Double
    public let ensemble: BoxEnsemble?

    public init(box: NormalizedBox?, confidence: Double, presence: Double, ensemble: BoxEnsemble? = nil) {
        self.box = box
        self.confidence = confidence
        self.presence = presence
        self.ensemble = ensemble
    }
}
