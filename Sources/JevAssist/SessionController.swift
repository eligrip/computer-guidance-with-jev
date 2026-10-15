import AppKit
import ApplicationServices
import JevAssistCore

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var transcript = ""
    @Published private(set) var goal: String?
    @Published private(set) var status = "Ready when you are"
    @Published private(set) var speechStatus = "Voice starts with your help session"
    @Published private(set) var hasAPIKey = false
    @Published private(set) var metrics = ""
    var onRunningChanged: ((Bool) -> Void)?

    private let speech = SpeechTranscriber()
    private let screens = ScreenObserver()
    private let overlay = HighlightOverlay()
    private var latch = HighlightLatch()
    private var client: JevClient?
    private var loop: Task<Void, Never>?
    private var guidanceTask: Task<Void, Never>?
    private var guidancePump: Task<Void, Never>?
    private var goalTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var typedTranscript = ""
    private var voiceTranscript = ""
    private var contextRevision: UInt64 = 0
    private var sessionID = UUID()
    private var lastDispatch = Date.distantPast
    private var nextAllowedDispatch = Date.distantPast
    private var nextGoalAt = Date.distantPast
    private var lastGoalTranscript = ""
    private var requestCount = 0
    private var failures = 0
    private var observingAssistant = false
    private var observingUnavailable = false

    init() {
        LocalStorage.prepare()
        if let key = LocalStorage.loadKey() { client = JevClient(apiKey: key); hasAPIKey = true }
        rememberObservedApp()
        speech.onText = { [weak self] text in
            guard let self else { return }
            self.voiceTranscript = text
            self.updateTranscript()
        }
        speech.onStatus = { [weak self] text in self?.speechStatus = text }
    }

    func rememberObservedApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
    }

    func returnToObservedApp() { previousApp?.activate(options: [.activateIgnoringOtherApps]) }

    func start() async {
        guard !isRunning else { return }
        guard client != nil else { status = "Add your TypeSafe API key in settings"; return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            status = "Enable Screen Recording for Jev Assist, then restart the app"
            return
        }
        sessionID = UUID()
        screens.reset()
        latch.beginSession()
        isRunning = true
        failures = 0
        requestCount = 0
        nextAllowedDispatch = .distantPast
        lastDispatch = .distantPast
        lastGoalTranscript = ""
        nextGoalAt = .distantPast
        observingAssistant = false
        observingUnavailable = false
        voiceTranscript = ""
        updateTranscript()
        status = "Listening · talk through what you want"
        onRunningChanged?(true)
        let startedSession = sessionID
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning, self.sessionID == startedSession {
                self.tick()
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
        }
        speechTask = Task { [weak self] in await self?.speech.start() }
    }

    func stop() {
        isRunning = false
        sessionID = UUID()
        loop?.cancel(); loop = nil
        guidanceTask?.cancel(); guidanceTask = nil
        guidancePump?.cancel(); guidancePump = nil
        goalTask?.cancel(); goalTask = nil
        speechTask?.cancel(); speechTask = nil
        speech.stop()
        latch.endSession()
        screens.reset()
        overlay.hide()
        status = "Session stopped"
        speechStatus = "Microphone off"
        onRunningChanged?(false)
    }

    func addTypedText(_ text: String) {
        typedTranscript = String([typedTranscript, text].filter { !$0.isEmpty }.joined(separator: "\n").suffix(8_000))
        updateTranscript()
    }

    private func updateTranscript() {
        let updated = String([typedTranscript, voiceTranscript].filter { !$0.isEmpty }.joined(separator: "\n").suffix(12_000))
        guard updated != transcript else { return }
        transcript = updated
        contextRevision &+= 1
        // New or revised speech never releases an accepted highlight.
        scheduleGuidancePump()
    }

    /// Coalesce fast speech updates and immediately use the newest context when
    /// a response arrives. The observation timer remains a screen-change backstop.
    private func scheduleGuidancePump() {
        guard isRunning, guidancePump == nil else { return }
        let pendingSession = sessionID
        guidancePump = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.isRunning, self.sessionID == pendingSession else { return }
            self.guidancePump = nil
            self.tick()
        }
    }

    private func tick() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            if !observingAssistant {
                observingAssistant = true
                latch.screenDidChange()
                screens.reset()
                overlay.hide()
            }
            status = "Session active · return to the app you want help with"
            return
        }
        observingAssistant = false
        previousApp = frontmost
        guard let frame = screens.capture(app: frontmost) else {
            if !observingUnavailable {
                observingUnavailable = true
                latch.screenDidChange(); overlay.hide(); screens.reset()
            }
            status = "Waiting for an app window to guide you in"
            return
        }
        observingUnavailable = false
        let observation = screens.observe(frame)
        if observation.changed { latch.screenDidChange(); overlay.hide() }
        inferGoalIfNeeded()
        guard observation.stable, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if transcript.isEmpty { status = "Listening · talk through what you want" }
            return
        }
        guard guidanceTask == nil, Date() >= nextAllowedDispatch,
              let client, let ticket = latch.makeRequest() else { return }
        let input = GuidanceInput(transcript: transcript, goal: goal, notes: LocalStorage.readNotes(),
                                  browserContext: LocalStorage.browserContext(for: frame.bundleID),
                                  accessibilityContext: screens.accessibilityContext(for: frame), imageJPEG: frame.jpeg)
        let requestSession = sessionID
        lastDispatch = Date()
        let started = Date()
        guidanceTask = Task { [weak self] in
            do {
                let result = try await client.guidance(input)
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.guidanceTask = nil
                defer { self.scheduleGuidancePump() }
                self.failures = 0
                self.requestCount += 1
                self.metrics = "\(self.requestCount) calls · \(Int(Date().timeIntervalSince(started) * 1000)) ms"
                // A new partial transcript does not invalidate a current-screen
                // answer: otherwise continuous speech could starve all guidance.
                // Re-capture before displaying to close the gap between ticks.
                guard let currentApp = NSWorkspace.shared.frontmostApplication,
                      currentApp.processIdentifier == frame.processID else {
                    self.latch.screenDidChange(); self.overlay.hide(); self.screens.reset()
                    return
                }
                // Discard an answer for different pixels; the observation loop
                // owns debounce and decides when to release an existing box.
                guard let currentFrame = self.screens.capture(app: currentApp),
                      self.screens.sameScene(frame, currentFrame) else { return }
                // Reject padded margins before locking the overlay in place.
                if let box = result.box, let rect = frame.screenRect(for: box), self.latch.apply(result, for: ticket) {
                    self.overlay.show(coreGraphicsRect: rect)
                }
                self.status = self.latch.box == nil ? "Listening · looking for a useful place to point" : "Highlight held · continue at your own pace"
            } catch {
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.guidanceTask = nil
                self.failures += 1
                let serviceError = error as? JevError
                let delay = serviceError?.retryAfter ?? min(15, pow(2, Double(min(self.failures, 4))) * 0.5)
                self.nextAllowedDispatch = Date().addingTimeInterval(delay)
                self.status = error.localizedDescription
                // A network failure does not erase the accepted box.
            }
        }
    }

    private func inferGoalIfNeeded() {
        guard goalTask == nil, Date() >= nextGoalAt, transcript != lastGoalTranscript,
              !transcript.isEmpty, let client else { return }
        let text = transcript
        let previous = goal
        let requestSession = sessionID
        nextGoalAt = Date().addingTimeInterval(2)
        lastGoalTranscript = text
        goalTask = Task { [weak self] in
            do {
                let inferred = try await client.inferGoal(transcript: text, previousGoal: previous)
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.goalTask = nil
                // Keep a verbatim anchor when new speech merely extends the same
                // thought. Reject text that a corrected partial has removed.
                if let inferred {
                    guard self.transcript.contains(inferred) || (inferred == previous && self.goal == previous) else { return }
                }
                if inferred != self.goal {
                    self.goal = inferred
                    self.contextRevision &+= 1
                    self.scheduleGuidancePump()
                }
            } catch {
                guard let self, !Task.isCancelled, self.sessionID == requestSession else { return }
                self.goalTask = nil
                self.lastGoalTranscript = ""
                self.nextGoalAt = Date().addingTimeInterval((error as? JevError)?.retryAfter ?? 5)
            }
        }
    }

    func saveAPIKey(_ key: String) {
        guard LocalStorage.saveKey(key) else { status = "Couldn’t save the API key to Keychain"; return }
        client = JevClient(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = true
        status = "API key saved in Keychain"
        nextAllowedDispatch = .distantPast
    }

    func openNotes() { NSWorkspace.shared.open(LocalStorage.notesURL) }

    func openScreenPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
