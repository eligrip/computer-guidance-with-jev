import Foundation

public enum JevError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidConfiguration
    case invalidImage(String)
    case invalidResponse(String)
    case http(statusCode: Int, retryAfter: TimeInterval?)
    case engine(message: String, retryAfter: TimeInterval?)

    public var retryAfter: TimeInterval? {
        switch self {
        case .http(_, let delay), .engine(_, let delay): return delay
        default: return nil
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 429 || (500...599).contains(status)
        case .engine(_, let delay): return delay != nil
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add a TypeSafe API key before starting a help session."
        case .invalidConfiguration: return "Jev confidence thresholds must be finite numbers between zero and one."
        case .invalidImage(let reason): return "Screen image could not be sent: \(reason)"
        case .invalidResponse(let reason): return "Jev returned an invalid answer: \(reason)"
        case .engine(let message, _): return message
        case .http(let status, _):
            switch status {
            case 401, 403: return "TypeSafe rejected the API key or its access (HTTP \(status))."
            case 429: return "TypeSafe rate limit reached. Guidance will resume after a short backoff."
            case 529: return "TypeSafe is temporarily overloaded. Guidance will retry shortly."
            default: return "TypeSafe request failed (HTTP \(status))."
            }
        }
    }
}

/// Native adapter to the Rust engine. HTTP, prompts, source-span selection,
/// confidence gating and retry metadata belong to Rust; no keys enter argv/logs.
public struct JevClient: Sendable {
    public let model: String
    public let minimumPresence: Double
    public let minimumConfidence: Double
    private let apiKey: String
    private let transport: RustEngineTransport

    public init(apiKey: String, model: String = "jev-1.14.0", minimumPresence: Double = 0.65,
                minimumConfidence: Double = 0.25) {
        self.init(apiKey: apiKey, model: model, minimumPresence: minimumPresence,
                  minimumConfidence: minimumConfidence, transport: RustEngineTransport())
    }

    init(apiKey: String, model: String = "jev-1.14.0", minimumPresence: Double = 0.65,
         minimumConfidence: Double = 0.25, transport: RustEngineTransport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.minimumPresence = minimumPresence
        self.minimumConfidence = minimumConfidence
        self.transport = transport
    }

    public func guidance(_ input: GuidanceInput) async throws -> GuidanceResult {
        let response = try await send(operation: "guidance", input: [
            "transcript": input.transcript, "goal": input.goal as Any? ?? NSNull(), "notes": input.notes,
            "browser_context": input.browserContext as Any? ?? NSNull(),
            "accessibility_context": input.accessibilityContext as Any? ?? NSNull(),
            "image_jpeg_base64": input.imageJPEG.base64EncodedString()
        ])
        struct Result: Decodable { let box: NormalizedBox?; let confidence: Double; let presence: Double }
        let result: Result = try decodeResult(response)
        guard result.box?.isValid != false, result.confidence.isFinite, (0...1).contains(result.confidence),
              result.presence.isFinite, (0...1).contains(result.presence) else {
            throw JevError.invalidResponse("Engine returned invalid box coordinates or probabilities.")
        }
        return GuidanceResult(box: result.box, confidence: result.confidence, presence: result.presence)
    }

    public func inferGoal(transcript: String, previousGoal: String?) async throws -> String? {
        let response = try await send(operation: "goal", input: [
            "transcript": transcript, "previous_goal": previousGoal as Any? ?? NSNull()
        ])
        struct Result: Decodable { let goal: String? }
        let result: Result = try decodeResult(response)
        return result.goal
    }

    private func send(operation: String, input: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw JevError.missingAPIKey }
        let id = UUID().uuidString
        let payload: [String: Any] = [
            "id": id, "op": operation, "api_key": apiKey, "model": model,
            "minimum_presence": minimumPresence, "minimum_confidence": minimumConfidence, "input": input
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload) else { throw JevError.invalidConfiguration }
        return try await transport.request(encoded, id: id)
    }

    private func decodeResult<T: Decodable>(_ data: Data) throws -> T {
        let reply: EngineReply<T>
        do { reply = try JSONDecoder().decode(EngineReply<T>.self, from: data) }
        catch { throw JevError.invalidResponse("The Rust engine returned malformed data.") }
        if !reply.ok {
            guard let error = reply.error else { throw JevError.invalidResponse("The engine error had no details.") }
            let retry = error.retry_after.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if let status = error.status { throw JevError.http(statusCode: status, retryAfter: retry) }
            throw JevError.engine(message: String(error.message.prefix(300)), retryAfter: retry)
        }
        guard let result = reply.result else { throw JevError.invalidResponse("The engine result was missing.") }
        return result
    }
}

private struct EngineReply<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: EngineFailure?
}

private struct EngineFailure: Decodable {
    let message: String
    let retry_after: Double?
    let status: Int?
}
