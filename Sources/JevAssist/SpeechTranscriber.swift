import AVFoundation
import Speech

/// Uses provisional hypotheses immediately. A recognizer restart commits only the
/// latest hypothesis once, so replacement partials never duplicate conversation.
@MainActor
final class SpeechTranscriber {
    var onText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var configuration = SpeechConfiguration(languageID: "en-US", mode: .onDeviceOnly)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var generation = UUID()
    private var committed = ""
    private var partial = ""
    private var running = false
    private var tapInstalled = false
    private var failures = 0

    func start(configuration: SpeechConfiguration, preservingTranscript: Bool = false) async {
        guard !Task.isCancelled else { return }
        let retained = preservingTranscript ? fullTranscript : ""
        stop()
        self.configuration = configuration
        committed = retained
        partial = ""
        onText?(fullTranscript)
        failures = 0
        running = true
        let sessionID = generation
        onStatus?("Requesting microphone and speech access…")
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard running, generation == sessionID, !Task.isCancelled else { return }
        guard microphone else { onStatus?("Microphone access is off. Open Speech settings to enable it."); return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard running, generation == sessionID, !Task.isCancelled else { return }
        guard authorization == .authorized else {
            onStatus?(authorization == .restricted ? "Speech recognition is restricted by this Mac’s policy." : "Speech recognition permission is off. Open Speech settings to enable it.")
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: configuration.languageID))
        // Give a newly initialized recognizer a chance to discover local assets.
        if recognizer?.supportsOnDeviceRecognition == false {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard running, generation == sessionID, !Task.isCancelled else { return }
        if let blocker = configuration.blocker(recognizerExists: recognizer != nil,
                                               onDeviceSupported: recognizer?.supportsOnDeviceRecognition ?? false,
                                               serviceAvailable: recognizer?.isAvailable ?? false) {
            onStatus?(blocker); return
        }
        beginRecognition()
    }

    func stop() {
        running = false
        generation = UUID()
        restartTask?.cancel()
        restartTask = nil
        tearDownAudio()
    }

    private func beginRecognition() {
        guard running, let recognizer else { return }
        // Recheck at every restart: Apple only honors the local-only request
        // flag while this capability is available.
        if configuration.requiresOnDeviceRecognition, !recognizer.supportsOnDeviceRecognition {
            stop()
            onStatus?(configuration.blocker(recognizerExists: true, onDeviceSupported: false, serviceAvailable: true)!)
            return
        }
        generation = UUID()
        let recognitionID = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = configuration.requiresOnDeviceRecognition
        request.taskHint = .dictation
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onStatus?("No microphone is available. You can type below.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch {
            tearDownAudio()
            onStatus?("Couldn’t start the microphone. You can type below.")
            return
        }
        let route = configuration.requiresOnDeviceRecognition ? "on this Mac" : "with Apple · online recognition allowed"
        onStatus?("Listening in \(configuration.languageName) \(route)")
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.running, self.generation == recognitionID else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onText?(self.fullTranscript)
                    self.failures = 0
                    if result.isFinal { self.scheduleRestart(after: 0.15); return }
                }
                if let error {
                    self.failures += 1
                    if let blocker = self.configuration.blocker(
                        recognizerExists: true,
                        onDeviceSupported: recognizer.supportsOnDeviceRecognition,
                        serviceAvailable: true), self.configuration.requiresOnDeviceRecognition {
                        self.stop()
                        self.onStatus?(blocker)
                        return
                    }
                    let code = (error as NSError).code
                    self.onStatus?("Reconnecting Apple speech (\(code))… You can retry from Speech settings.")
                    self.scheduleRestart(after: min(8, Double(self.failures)))
                }
            }
        }
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, self.running, self.generation == recognitionID else { return }
            self.scheduleRestart(after: 0.1)
        }
    }

    private var fullTranscript: String {
        [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func scheduleRestart(after delay: Double) {
        guard running else { return }
        restartTask?.cancel()
        committed = String(fullTranscript.suffix(12_000))
        partial = ""
        generation = UUID()
        let pendingID = generation
        tearDownAudio()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.running, self.generation == pendingID else { return }
            self.beginRecognition()
        }
    }

    private func tearDownAudio() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
    }
}
