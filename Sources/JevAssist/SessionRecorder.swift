import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import JevAssistCore

/// Local replay evidence, never microphone audio or application credentials.
/// Admission is bounded on the caller; all file work runs on a serial queue.
@MainActor
final class SessionRecorder {
    static var recordingsURL: URL { LocalStorage.directory.appendingPathComponent("recordings", isDirectory: true) }
    static var defaultEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let argumentRoot = arguments.firstIndex(of: "--project-root").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        var roots: [String?] = [argumentRoot, ProcessInfo.processInfo.environment["JEV_ASSIST_PROJECT_ROOT"],
                               FileManager.default.currentDirectoryPath]
        var ancestor = Bundle.main.bundleURL
        for _ in 0..<6 {
            ancestor.deleteLastPathComponent()
            roots.append(ancestor.path)
        }
        return roots.compactMap { $0 }.contains { isDeveloperCheckout(URL(fileURLWithPath: $0)) }
    }
    static func isDeveloperCheckout(_ root: URL) -> Bool {
        [".git", "Package.swift", "Sources/JevAssist/SessionController.swift", "engine/Cargo.toml"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    var onStatusChange: ((Bool, String) -> Void)?
    private let queue = DispatchQueue(label: "ai.typesafe.jevassist.recordings", qos: .utility)
    private let writer: SessionRecordingWriter
    private let budget: RecordingQueueBudget
    private var activeToken: UUID?
    private var startedAt: TimeInterval = 0
    private var lastContext: (String, String?, String?, String?)?

    init(rootURL: URL? = nil, limits: RecordingLimits = RecordingLimits()) {
        writer = SessionRecordingWriter(root: rootURL ?? Self.recordingsURL, limits: limits)
        budget = RecordingQueueBudget(maxBytes: limits.queuedBytes, maxItems: limits.queuedItems)
    }

    func start(sessionID: UUID) {
        if activeToken != nil { stop(reason: "recording_restarted") }
        let token = UUID()
        activeToken = token
        startedAt = ProcessInfo.processInfo.systemUptime
        lastContext = nil
        onStatusChange?(true, "Recording locally")
        queue.async { [writer, weak self] in
            do { try writer.start(token: token, sessionID: sessionID) }
            catch { writer.abandon(); Task { @MainActor [weak self] in self?.didFail(token: token, error: error) } }
        }
    }

    func stop(reason: String = "session_stopped") {
        guard let token = activeToken else { return }
        let event = event("session_stopped", reason: String(reason.prefix(256)))
        activeToken = nil
        lastContext = nil
        queue.async { [writer] in
            guard writer.token == token else { return }
            try? writer.append(event)
            writer.close()
        }
        onStatusChange?(false, "Recording saved on this Mac")
    }

    @discardableResult
    func recordFrame(_ frame: ScreenSnapshot, generation: UInt64) -> String? {
        guard activeToken != nil else { return nil }
        let frameID = UUID().uuidString
        var entry = event("frame")
        entry.frameID = frameID
        entry.generation = generation
        entry.windowID = frame.windowID
        entry.appBundleID = frame.bundleID.map { String($0.prefix(256)) }
        entry.appName = String(frame.appName.prefix(256))
        entry.windowTitle = String(frame.windowTitle.prefix(512))
        entry.screenBounds = RecordingRect(frame.screenBounds)
        entry.imageContentRect = RecordingRect(frame.imageContentRect)
        let jpeg = frame.jpeg
        return enqueue(cost: jpeg.count + 4096) { try $0.appendFrame(entry, jpeg: jpeg) } ? frameID : nil
    }

    func recordContext(transcript: String, goal: String?, currentUtterance: String? = nil, task: String? = nil) {
        let text = TranscriptContext.retainingRecent(transcript)
        let anchor = goal.map { String($0.prefix(2_000)) }
        let task = task.map { String($0.prefix(2_000)) }
        let utterance = currentUtterance.flatMap { text.contains($0) ? String($0.prefix(4_000)) : nil }
        guard lastContext?.0 != text || lastContext?.1 != anchor || lastContext?.2 != utterance || lastContext?.3 != task else { return }
        var entry = event("context")
        entry.transcript = text
        entry.goal = anchor
        entry.task = task
        entry.currentUtterance = utterance
        if enqueue(entry) { lastContext = (text, anchor, utterance, task) }
    }

    func recordSpeech(_ telemetry: SpeechRecognitionTelemetry) {
        var entry = event("speech_recognition")
        entry.speech = telemetry
        _ = enqueue(entry)
    }

    func recordGoal(sequence: UInt64, latencyMS: Double? = nil, disposition: String, reason: String? = nil) {
        var entry = event("goal", reason: reason)
        entry.requestID = "goal-\(sequence)"
        entry.latencyMS = latencyMS?.finiteValue
        entry.disposition = disposition
        _ = enqueue(entry)
    }

    func recordDecision(requestID: String, frameID: String?, result: GuidanceResult?, latencyMS: Double,
                        disposition: String, reason: String, targetRect: CGRect? = nil) {
        var entry = event("decision", reason: String(reason.prefix(512)))
        entry.requestID = String(requestID.prefix(128))
        entry.frameID = frameID
        entry.confidence = result?.confidence.finiteValue
        entry.presence = result?.presence.finiteValue
        entry.activity = result?.activity?.finiteValue
        entry.box = result?.box.flatMap { $0.isValid ? $0 : nil }
        entry.ensemble = result?.ensemble
        entry.latencyMS = latencyMS.finiteValue
        entry.disposition = String(disposition.prefix(128))
        entry.targetRect = targetRect.flatMap(RecordingRect.init)
        _ = enqueue(entry)
    }

    func recordHighlight(reason: String, frameID: String? = nil, box: NormalizedBox? = nil, targetRect: CGRect? = nil) {
        var entry = event("highlight", reason: String(reason.prefix(512)))
        entry.frameID = frameID
        entry.box = box.flatMap { $0.isValid ? $0 : nil }
        entry.targetRect = targetRect.flatMap(RecordingRect.init)
        _ = enqueue(entry)
    }

    func recordSetting(name: String, value: String) {
        // Only operational tuning fields can enter this stream; no key/config dump.
        guard ["guidance_pace", "box_sampling", "highlight_style", "speech_mode", "speech_language", "recording"].contains(name) else { return }
        var entry = event("setting")
        entry.settingName = name
        entry.settingValue = String(value.prefix(128))
        _ = enqueue(entry)
    }

    /// Only app exit waits for queued evidence; live guidance remains asynchronous.
    func finishPendingWritesForExit() { queue.sync {} }

    func flushForTesting() { finishPendingWritesForExit() }

    private func event(_ kind: String, reason: String? = nil) -> RecordingEvent {
        RecordingEvent(kind: kind, timestampMS: Date().timeIntervalSince1970 * 1000,
                       elapsedMS: max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1000, reason: reason)
    }

    @discardableResult
    private func enqueue(_ event: RecordingEvent) -> Bool {
        enqueue(cost: (event.transcript?.utf8.count ?? 0) + (event.goal?.utf8.count ?? 0) + (event.task?.utf8.count ?? 0) + 4096) { try $0.append(event) }
    }

    private func enqueue(cost: Int, operation: @escaping (SessionRecordingWriter) throws -> Void) -> Bool {
        guard let token = activeToken, budget.reserve(cost) else { return false }
        queue.async { [writer, budget, weak self] in
            defer { budget.release(cost) }
            guard writer.token == token else { return }
            do { try operation(writer) }
            catch {
                writer.abandon()
                Task { @MainActor [weak self] in self?.didFail(token: token, error: error) }
            }
        }
        return true
    }

    private func didFail(token: UUID, error: Error) {
        guard activeToken == token else { return }
        activeToken = nil
        let message: String
        if error is RecordingStorageLimit { message = "Recording paused: local storage limit reached" }
        else if error is RecordingWriterUnavailable { message = "Recording paused: another Jev Assist instance is recording" }
        else { message = "Recording paused: couldn’t write to disk" }
        onStatusChange?(false, message)
    }
}

struct RecordingLimits {
    var sessionBytes = 256 * 1024 * 1024
    var totalBytes = 1024 * 1024 * 1024
    var sessions = 20
    var queuedBytes = 32 * 1024 * 1024
    var queuedItems = 128
}

/// A saturated disk queue drops evidence, never backs up the guidance loop.
final class RecordingQueueBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let maxItems: Int
    private var bytes = 0
    private var items = 0
    init(maxBytes: Int, maxItems: Int) { self.maxBytes = maxBytes; self.maxItems = maxItems }
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= maxBytes - bytes, items < maxItems else { return false }
        bytes += count; items += 1
        return true
    }
    func release(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        bytes = max(0, bytes - count); items = max(0, items - 1)
    }
}

private extension Double { var finiteValue: Double? { isFinite ? self : nil } }

struct RecordingRect: Codable {
    let x: Double, y: Double, width: Double, height: Double
    init?(_ rect: CGRect) {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }
}

struct RecordingEvent: Codable {
    var schemaVersion = 1
    var sequence = 0
    var kind: String
    var timestampMS: Double
    var elapsedMS: Double
    var reason: String?
    var frameID: String?
    var generation: UInt64?
    var imagePath: String?
    var windowID: UInt32?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var screenBounds: RecordingRect?
    var imageContentRect: RecordingRect?
    var requestID: String?
    var transcript: String?
    var goal: String?
    var task: String?
    var currentUtterance: String?
    var speech: SpeechRecognitionTelemetry?
    var confidence: Double?
    var presence: Double?
    var activity: Double?
    var box: NormalizedBox?
    var ensemble: BoxEnsemble?
    var targetRect: RecordingRect?
    var latencyMS: Double?
    var disposition: String?
    var settingName: String?
    var settingValue: String?
}

private struct RecordingStorageLimit: Error {}
private struct RecordingWriterUnavailable: Error {}

/// Accessed on SessionRecorder's serial queue, or synchronously by synthetic tests.
final class SessionRecordingWriter {
    private(set) var token: UUID?
    private let root: URL
    private let limits: RecordingLimits
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private var directory: URL?
    private var handle: FileHandle?
    private var lockHandle: FileHandle?
    private var sequence = 0
    private var bytes = 0
    private var older: [(url: URL, bytes: Int)] = []
    private var imageHashes = Set<String>()

    init(root: URL, limits: RecordingLimits) {
        self.root = root; self.limits = limits
        encoder.outputFormatting = [.sortedKeys]
        // Keep even malformed sample evidence inspectable without stopping the
        // recording. Valid probabilities/coordinates retain their exact values.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    }
    deinit { close() }

    func start(token: UUID, sessionID: UUID) throws {
        close()
        try secureDirectory(root)
        // One writer per recordings folder prevents another app instance from
        // pruning a live run or evading the shared retention limit.
        let lockURL = root.appendingPathComponent(".writer.lock")
        if let info = try? lockURL.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        if !fm.fileExists(atPath: lockURL.path) {
            guard fm.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let fileLock = try FileHandle(forUpdating: lockURL)
        guard flock(fileLock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? fileLock.close()
            throw RecordingWriterUnavailable()
        }
        lockHandle = fileLock
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        older = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                guard url.lastPathComponent.hasPrefix("session-"),
                      let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      info.isDirectory == true, info.isSymbolicLink != true else { return false }
                return true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, directoryBytes($0)) }
        while older.count >= max(1, limits.sessions) { try pruneOldest() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let run = root.appendingPathComponent("session-\(formatter.string(from: Date()))-\(token.uuidString)", isDirectory: true)
        try secureDirectory(run)
        try secureDirectory(run.appendingPathComponent("frames", isDirectory: true))
        directory = run
        self.token = token
        bytes = 0; sequence = 0; imageHashes = []
        let metadata: [String: Any] = ["schemaVersion": 1, "sessionID": sessionID.uuidString,
                                     "startedAtMS": Date().timeIntervalSince1970 * 1000, "rawAudio": false,
                                     "events": "events.ndjson", "coordinates": "Core Graphics desktop points; normalized boxes refer to prepared JPEG"]
        let manifest = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let review = Data(RecordingReviewPage.html.utf8)
        try checkSpace(manifest.count + review.count)
        try secureWrite(manifest, to: run.appendingPathComponent("manifest.json"))
        bytes += manifest.count
        try secureWrite(review, to: run.appendingPathComponent("review.html"))
        bytes += review.count
        let events = run.appendingPathComponent("events.ndjson")
        guard fm.createFile(atPath: events.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: events)
        try append(RecordingEvent(kind: "session_started", timestampMS: Date().timeIntervalSince1970 * 1000, elapsedMS: 0))
    }

    func appendFrame(_ original: RecordingEvent, jpeg: Data) throws {
        guard let directory, handle != nil else { return }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        var event = original
        event.imagePath = "frames/\(digest).jpg"
        let isNew = !imageHashes.contains(digest)
        var encodedEvent = event
        encodedEvent.sequence = sequence + 1
        let eventBytes = try encoder.encode(encodedEvent).count + 1
        try checkSpace(eventBytes + (isNew ? jpeg.count : 0))
        if isNew {
            try secureWrite(jpeg, to: directory.appendingPathComponent(event.imagePath!))
            bytes += jpeg.count
            imageHashes.insert(digest)
        }
        try append(event)
    }

    func append(_ original: RecordingEvent) throws {
        guard let handle else { return }
        var event = original
        event.sequence = sequence + 1
        var data = try encoder.encode(event)
        data.append(0x0a)
        try checkSpace(data.count)
        try handle.write(contentsOf: data)
        bytes += data.count; sequence += 1
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil; token = nil; directory = nil
        if let lockHandle { flock(lockHandle.fileDescriptor, LOCK_UN); try? lockHandle.close() }
        lockHandle = nil
    }
    func abandon() { close() }

    private func secureDirectory(_ url: URL) throws {
        if let info = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func checkSpace(_ incoming: Int) throws {
        guard incoming <= limits.sessionBytes - bytes, incoming <= limits.totalBytes - bytes else { throw RecordingStorageLimit() }
        while bytes + incoming + older.reduce(0, { $0 + $1.bytes }) > limits.totalBytes { try pruneOldest() }
    }
    private func pruneOldest() throws {
        guard let old = older.first else { throw RecordingStorageLimit() }
        try fm.removeItem(at: old.url)
        older.removeFirst()
    }
    private func directoryBytes(_ url: URL) -> Int {
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                        options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let file as URL in files {
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if info.isSymbolicLink == true { files.skipDescendants(); continue }
            if info.isRegularFile == true { total += info.fileSize ?? 0 }
        }
        return total
    }
}
