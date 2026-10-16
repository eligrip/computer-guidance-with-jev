import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Pipe bookkeeping lives off the UI actor. Cancellation releases the caller
/// immediately but keeps its remote slot occupied until Rust's operation ends.
final class RustEngineTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.typesafe.jevassist.engine")
    private let writer = DispatchQueue(label: "ai.typesafe.jevassist.engine.stdin")
    private let executableURL: URL?
    private let arguments: [String]
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation: UInt64 = 0
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var outstanding: Set<String> = []
    private var timeouts: [String: DispatchWorkItem] = [:]

    init(executableURL: URL? = nil, arguments: [String] = [], requestTimeout: TimeInterval = 40) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    deinit {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        for timeout in timeouts.values { timeout.cancel() }
        for continuation in pending.values {
            continuation.resume(throwing: JevError.engine(message: "The guidance engine stopped.", retryAfter: 1))
        }
    }

    func request(_ payload: Data, id: String) async throws -> Data {
        let cancellation = CancellationFlag()
        let result: Data = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard outstanding.count < 10 else {
                        continuation.resume(throwing: JevError.engine(message: "Finishing the previous guidance requests…", retryAfter: 0.25))
                        return
                    }
                    do { try startIfNeeded() }
                    catch { continuation.resume(throwing: error); return }
                    guard let input else {
                        continuation.resume(throwing: JevError.engine(message: "The guidance engine is unavailable.", retryAfter: 1))
                        return
                    }
                    let currentGeneration = generation
                    pending[id] = continuation
                    outstanding.insert(id)
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == currentGeneration, self.outstanding.contains(id) else { return }
                        self.stopProcess(error: JevError.engine(message: "The guidance engine timed out. Retrying shortly.", retryAfter: 1))
                    }
                    timeouts[id] = timeout
                    queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
                    let line = payload + Data([0x0a])
                    writer.async { [weak self] in
                        do { try input.write(contentsOf: line) }
                        catch {
                            self?.queue.async { [weak self] in
                                guard let self, self.generation == currentGeneration else { return }
                                self.stopProcess(error: JevError.engine(message: "The guidance engine connection closed.", retryAfter: 1))
                            }
                        }
                    }
                }
            }
        }, onCancel: { [weak self] in
            cancellation.cancel()
            self?.queue.async { [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        })
        try Task.checkCancellation()
        return result
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        if process != nil { stopProcess(error: JevError.engine(message: "The guidance engine restarted.", retryAfter: 1)) }
        guard let executable = executableURL ?? Self.locateExecutable(),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw JevError.engine(message: "The Rust guidance engine is missing. Rebuild Jev Assist with scripts/build.sh.", retryAfter: nil)
        }
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        #if canImport(Darwin)
        // A helper that exits while a screenshot is being written must become
        // a recoverable EPIPE, never terminate the native app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        task.executableURL = executable
        task.arguments = arguments
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        generation &+= 1
        let currentGeneration = generation
        task.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.stopProcess(error: JevError.engine(message: "The Rust guidance engine stopped. Retrying shortly.", retryAfter: 1))
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                if data.isEmpty {
                    self.stopProcess(error: JevError.engine(message: "The guidance engine connection closed.", retryAfter: 1))
                } else { self.receive(data) }
            }
        }
        do { try task.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            task.terminationHandler = nil
            throw JevError.engine(message: "The Rust guidance engine could not start. Rebuild Jev Assist.", retryAfter: nil)
        }
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else {
            stopProcess(error: JevError.invalidResponse("The engine reply exceeded its size limit.")); return
        }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = json["id"] as? String, json["ok"] is Bool else {
                stopProcess(error: JevError.invalidResponse("The Rust engine returned malformed data.")); return
            }
            outstanding.remove(id)
            timeouts.removeValue(forKey: id)?.cancel()
            pending.removeValue(forKey: id)?.resume(returning: line)
        }
    }

    private func stopProcess(error: Error) {
        generation &+= 1
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        input = nil
        output = nil
        process = nil
        buffer.removeAll(keepingCapacity: false)
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        outstanding.removeAll()
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func locateExecutable() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["JEV_ASSIST_ENGINE_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("jev-assist-engine"))
        }
        var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--project-root"), index + 1 < args.count { roots.insert(URL(fileURLWithPath: args[index + 1]), at: 0) }
        if let root = env["JEV_ASSIST_PROJECT_ROOT"] { roots.insert(URL(fileURLWithPath: root), at: 0) }
        roots.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        for root in roots {
            for configuration in ["release", "debug"] {
                candidates.append(root.appendingPathComponent("engine/target/\(configuration)/jev-assist-engine"))
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
