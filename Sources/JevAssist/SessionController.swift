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
    @Published private(set) var speechLanguageID: String
    @Published private(set) var speechMode: SpeechRecognitionMode
    @Published private(set) var highlightStyle = HighlightStyle.restored(UserDefaults.standard.string(forKey: "highlightStyle"))
    @Published private(set) var guidancePace = GuidancePace.restored(UserDefaults.standard.string(forKey: "guidancePace"))
    @Published private(set) var boxSampling = BoxSampling.restored(UserDefaults.standard.string(forKey: "boxSampling"))
    @Published private(set) var recordingEnabled = UserDefaults.standard.object(forKey: "recordSessions") as? Bool ?? SessionRecorder.defaultEnabled
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStatus = ""
    let speechLanguages: [SpeechLanguage]
    var onRunningChanged: ((Bool) -> Void)?

    var conversationFocus: ConversationFocus {
        ConversationFocus(transcript: transcript, selectedGoal: goal)
    }

    private let speech = SpeechTranscriber()
    private let screens = ScreenObserver()
    private let overlay = HighlightOverlay()
    private var latch = HighlightLatch()
    private let recorder = SessionRecorder()
    private var client: JevClient?
    private var loop: Task<Void, Never>?
    private var guidanceTasks: [UUID: Task<Void, Never>] = [:]
    private var guidancePump: Task<Void, Never>?
    private var goalTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var conversation = SessionTranscript()
    private var pendingTypedText = ""
    private var contextRevision: UInt64 = 0
    private var sessionID = UUID()
    private var lastDispatch = Date.distantPast
    private var nextAllowedDispatch = Date.distantPast
    private var nextGoalAt = Date.distantPast
    private var lastGoalTranscript = ""
    private var lastGoalCheck = Date.distantPast
    private var requestCount = 0
    private var goalRequestCount = 0
    private var failures = 0
    private var observedAppPID: pid_t?
    private var observedNoSurfaces = false
    private var completions: [Date] = []
    private var dispatchCount = 0
    private var lastDispatchedSampling: BoxSampling = .single

    init() {
        speechLanguages = SpeechLanguage.available
        speechLanguageID = SpeechLanguage.resolve(saved: UserDefaults.standard.string(forKey: "speechLanguageID"),
                                                   preferred: Locale.preferredLanguages,
                                                   available: speechLanguages.map(\.id))
        speechMode = SpeechRecognitionMode.restored(UserDefaults.standard.string(forKey: "speechRecognitionMode"))
        overlay.style = highlightStyle
        LocalStorage.prepare()
        recorder.onStatusChange = { [weak self] active, message in
            self?.isRecording = active
            self?.recordingStatus = message
        }
        if let key = LocalStorage.loadKey() { client = JevClient(apiKey: key); hasAPIKey = true }
        rememberObservedApp()
        speech.onText = { [weak self] text in
            guard let self else { return }
            self.conversation.updateVoice(text)
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
        goal = nil
        screens.reset()
        latch.beginSession()
        isRunning = true
        failures = 0
        requestCount = 0
        goalRequestCount = 0
        dispatchCount = 0
        nextAllowedDispatch = .distantPast
        lastDispatch = .distantPast
        lastGoalTranscript = ""
        lastGoalCheck = .distantPast
        nextGoalAt = .distantPast
        observedAppPID = nil
        observedNoSurfaces = false
        completions.removeAll()
        metrics = ""
        if recordingEnabled { startRecording() }
        conversation.reset()
        conversation.appendTyped(pendingTypedText)
        pendingTypedText = ""
        updateTranscript()
        recorder.recordContext(transcript: transcript, goal: goal)
        status = "Listening · talk through what you want"
        onRunningChanged?(true)
        let startedSession = sessionID
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning, self.sessionID == startedSession {
                self.tick()
                try? await Task.sleep(nanoseconds: self.guidancePace.observationInterval)
            }
        }
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.isRunning, self.sessionID == startedSession else { return }
            await self.speech.start(configuration: self.speechConfiguration)
        }
    }

    func stop() {
        isRunning = false
        sessionID = UUID()
        loop?.cancel(); loop = nil
        guidanceTasks.values.forEach { $0.cancel() }; guidanceTasks.removeAll()
        guidancePump?.cancel(); guidancePump = nil
        goalTask?.cancel(); goalTask = nil
        speechTask?.cancel(); speechTask = nil
        speech.stop()
        latch.endSession()
        screens.reset()
        overlay.hide()
        recorder.recordHighlight(reason: "session_stopped")
        recorder.stop()
        status = "Session stopped"
        speechStatus = "Microphone off"
        onRunningChanged?(false)
    }

    func prepareForAppExit() {
        stop()
        recorder.finishPendingWritesForExit()
    }

    func addTypedText(_ text: String) {
        if !isRunning {
            if pendingTypedText.isEmpty { conversation.reset() }
            pendingTypedText = TranscriptContext.retainingRecent([pendingTypedText, text].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        conversation.appendTyped(text)
        updateTranscript()
    }

    private func updateTranscript() {
        let updated = conversation.text
        guard updated != transcript else { return }
        transcript = updated
        contextRevision &+= 1
        recorder.recordContext(transcript: transcript, goal: goal)
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
        // Spoken intent keeps updating even while the session panel is open or
        // screen capture is temporarily unavailable.
        inferGoalIfNeeded()
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        if observedAppPID != frontmost.processIdentifier {
            observedAppPID = frontmost.processIdentifier
            observedNoSurfaces = false
            latch.screenDidChange(); overlay.hide(); screens.reset()
            recorder.recordHighlight(reason: "foreground_changed")
        }
        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            status = "Session active · return to the app you want help with"
            return
        }
        previousApp = frontmost
        guard let frame = screens.capture(app: frontmost) else {
            if screens.captureConfirmedNoSurfaces && !observedNoSurfaces {
                observedNoSurfaces = true
                latch.screenDidChange(); overlay.hide(); screens.reset()
                recorder.recordHighlight(reason: "visible_surfaces_closed")
            }
            // A transient capture failure is not evidence that a held target
            // moved. The next valid frame determines whether it must clear.
            status = "Listening · waiting for a visible app or Dock"
            return
        }
        observedNoSurfaces = false
        let observation = screens.observe(frame)
        if observation.changed {
            latch.screenDidChange(); overlay.hide()
            recorder.recordHighlight(reason: "screen_changed")
        }
        guard observation.stable, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if transcript.isEmpty { status = "Listening · talk through what you want" }
            return
        }
        guard guidanceTasks.isEmpty || lastDispatchedSampling == boxSampling else { return }
        guard guidancePace.canDispatch(inFlight: guidanceTasks.count, lastDispatch: lastDispatch,
                                       retryAfter: nextAllowedDispatch, now: Date(), sampling: boxSampling),
              let client else { return }
        // Give small Dock icons a dedicated image on alternating requests.
        // Freshness still belongs to the full original scene; coordinates belong
        // to the exact image sent to Jev.
        let requestFrame = dispatchCount % 2 == 1 ? (frame.focusedOnDock() ?? frame) : frame
        let dockOnly = !frame.dockSurfaceIDs.isEmpty && requestFrame.surfaceIDs == frame.dockSurfaceIDs
        guard let ticket = latch.makeRequest(view: dockOnly ? .dock : .scene) else { return }
        dispatchCount += 1
        let scope = dockOnly
            ? "Image scope: visible Dock only. The active app is \(frame.appName), window \(frame.windowTitle). An app icon is useful only if opening or switching apps advances the latest request. If the active app already contains the next useful control, no Dock target is needed. "
            : "Image scope: active app and visible Dock. "
        let requestSampling = boxSampling
        let input = GuidanceInput(transcript: transcript, goal: goal, notes: LocalStorage.readNotes(),
                                  browserContext: LocalStorage.browserContext(for: frame.bundleID),
                                  accessibilityContext: scope + (screens.accessibilityContext(for: requestFrame) ?? ""),
                                  imageJPEG: requestFrame.jpeg, sampling: requestSampling)
        let requestSession = sessionID
        let requestID = UUID()
        let frameID = recorder.recordFrame(requestFrame, generation: ticket.screenGeneration)
        recorder.recordContext(transcript: transcript, goal: goal)
        lastDispatch = Date()
        lastDispatchedSampling = requestSampling
        let started = Date()
        guidanceTasks[requestID] = Task { [weak self] in
            do {
                let result = try await client.guidance(input)
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.guidanceTasks.removeValue(forKey: requestID)
                defer { self.scheduleGuidancePump() }
                self.failures = 0
                self.requestCount += requestSampling.sampleCount
                let now = Date()
                let latency = now.timeIntervalSince(started) * 1000
                self.updateMetrics(latencyMS: latency, completedCalls: requestSampling.sampleCount)
                guard self.boxSampling == requestSampling else {
                    self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: result,
                        latencyMS: latency, disposition: "suppressed", reason: "box_check_mode_changed")
                    return
                }
                // A new partial transcript does not invalidate a current-screen
                // answer: otherwise continuous speech could starve all guidance.
                // Re-capture before displaying to close the gap between ticks.
                guard let currentApp = NSWorkspace.shared.frontmostApplication,
                      currentApp.processIdentifier == frame.processID else {
                    self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: result,
                        latencyMS: latency, disposition: "suppressed", reason: "foreground_changed")
                    // An old response must never clear a newer screen's box.
                    return
                }
                // Discard an answer for different pixels; the observation loop
                // owns debounce and decides when to release an existing box.
                guard let currentFrame = self.screens.capture(app: currentApp),
                      self.screens.sameScene(frame, currentFrame) else {
                    self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: result,
                        latencyMS: latency, disposition: "suppressed", reason: "screen_changed_during_request")
                    return
                }
                // Reject padded margins before locking the overlay in place.
                let rect = result.box.flatMap { requestFrame.screenRect(for: $0) }
                let mappedResult = GuidanceResult(box: rect == nil ? nil : result.box,
                                                  confidence: result.confidence, presence: result.presence)
                let accepted = self.latch.apply(mappedResult, for: ticket)
                if accepted, let box = result.box, let rect {
                    self.overlay.show(coreGraphicsRect: rect)
                    self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: result,
                        latencyMS: latency, disposition: "displayed", reason: "accepted", targetRect: rect)
                    self.recorder.recordHighlight(reason: "accepted", frameID: frameID, box: box, targetRect: rect)
                } else {
                    let reason = self.latch.box != nil ? "existing_highlight_held" :
                        (result.box == nil ? (result.ensemble?.method ?? "presence_or_confidence_gate") : "stale_ticket_or_outside_image")
                    self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: result,
                        latencyMS: latency, disposition: "suppressed", reason: reason)
                }
                self.status = self.latch.box == nil ? "Listening · looking for a useful place to point" : "Highlight held · continue at your own pace"
            } catch {
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.guidanceTasks.removeValue(forKey: requestID)
                self.failures += 1
                let serviceError = error as? JevError
                if let completed = serviceError?.completedCalls, completed > 0 {
                    self.requestCount += completed
                    self.updateMetrics(latencyMS: Date().timeIntervalSince(started) * 1000, completedCalls: completed)
                }
                let delay = serviceError?.retryAfter ?? min(15, pow(2, Double(min(self.failures, 4))) * 0.5)
                self.nextAllowedDispatch = max(self.nextAllowedDispatch, Date().addingTimeInterval(delay))
                self.recorder.recordDecision(requestID: requestID.uuidString, frameID: frameID, result: nil,
                    latencyMS: Date().timeIntervalSince(started) * 1000, disposition: "failed", reason: error.localizedDescription)
                self.status = error.localizedDescription
                // A network failure does not erase the accepted box.
            }
        }
    }

    private func inferGoalIfNeeded() {
        guard goalTask == nil, Date() >= nextGoalAt, Date() >= nextAllowedDispatch,
              transcript != lastGoalTranscript || Date().timeIntervalSince(lastGoalCheck) >= 2,
              !transcript.isEmpty, let client else { return }
        let text = transcript
        let previous = goal
        let requestSession = sessionID
        let started = Date()
        nextGoalAt = started.addingTimeInterval(guidancePace == .fast ? 0.4 : 1)
        lastGoalTranscript = text
        lastGoalCheck = started
        goalTask = Task { [weak self] in
            do {
                let inferred = try await client.inferGoal(transcript: text, previousGoal: previous)
                guard let self, !Task.isCancelled, self.isRunning, self.sessionID == requestSession else { return }
                self.goalTask = nil
                self.goalRequestCount += 1
                self.updateMetrics(latencyMS: Date().timeIntervalSince(started) * 1000)
                let speechAdvanced = self.transcript != text
                if speechAdvanced {
                    // Reconsider new words immediately, but continuous speech
                    // must not starve a still-present verbatim goal selection.
                    self.lastGoalTranscript = ""
                    self.nextGoalAt = .distantPast
                    self.scheduleGuidancePump()
                    if inferred == nil { return }
                }
                // Keep a verbatim anchor when new speech merely extends the same
                // thought. Reject text that a corrected partial has removed.
                if let inferred {
                    guard self.transcript.contains(inferred) || (inferred == previous && self.goal == previous) else { return }
                }
                if inferred != self.goal {
                    self.goal = inferred
                    self.contextRevision &+= 1
                    self.recorder.recordContext(transcript: self.transcript, goal: inferred)
                    self.scheduleGuidancePump()
                }
            } catch {
                guard let self, !Task.isCancelled, self.sessionID == requestSession else { return }
                self.goalTask = nil
                self.lastGoalTranscript = ""
                let serviceError = error as? JevError
                let retry = serviceError?.retryAfter ?? 5
                self.nextGoalAt = Date().addingTimeInterval(retry)
                if serviceError?.isRetryable == true {
                    self.nextAllowedDispatch = max(self.nextAllowedDispatch, Date().addingTimeInterval(retry))
                }
            }
        }
    }

    private func updateMetrics(latencyMS: Double, completedCalls: Int = 1) {
        let now = Date()
        completions.append(contentsOf: repeatElement(now, count: completedCalls))
        completions.removeAll { now.timeIntervalSince($0) > 5 }
        metrics = "\(requestCount) target · \(goalRequestCount) goal · \(String(format: "%.1f", Double(completions.count) / 5))/s · \(Int(latencyMS))ms"
    }

    func saveAPIKey(_ key: String) {
        guard LocalStorage.saveKey(key) else { status = "Couldn’t save the API key to Keychain"; return }
        client = JevClient(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = true
        status = "API key saved in Keychain"
        nextAllowedDispatch = .distantPast
    }

    func openNotes() { NSWorkspace.shared.open(LocalStorage.notesURL) }

    func setGuidancePace(_ pace: GuidancePace) {
        guidancePace = pace
        UserDefaults.standard.set(pace.rawValue, forKey: "guidancePace")
        recorder.recordSetting(name: "guidance_pace", value: pace.rawValue)
        scheduleGuidancePump()
    }

    func setBoxSampling(_ sampling: BoxSampling) {
        boxSampling = sampling
        UserDefaults.standard.set(sampling.rawValue, forKey: "boxSampling")
        recorder.recordSetting(name: "box_sampling", value: sampling.rawValue)
        // Finish existing work before switching batch sizes. A setting change
        // cannot release or move a highlight on the current screen.
        scheduleGuidancePump()
    }

    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "recordSessions")
        if enabled && isRunning {
            startRecording()
            recorder.recordContext(transcript: transcript, goal: goal)
        } else if !enabled { recorder.stop(reason: "recording_disabled") }
    }

    func openRecordings() { NSWorkspace.shared.open(SessionRecorder.recordingsURL) }

    private func startRecording() {
        recorder.start(sessionID: sessionID)
        recorder.recordSetting(name: "guidance_pace", value: guidancePace.rawValue)
        recorder.recordSetting(name: "box_sampling", value: boxSampling.rawValue)
        recorder.recordSetting(name: "highlight_style", value: highlightStyle.rawValue)
        recorder.recordSetting(name: "speech_mode", value: speechMode.rawValue)
        recorder.recordSetting(name: "speech_language", value: speechLanguageID)
    }

    func setHighlightStyle(_ style: HighlightStyle) {
        highlightStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "highlightStyle")
        recorder.recordSetting(name: "highlight_style", value: style.rawValue)
        // Restyle the existing target in place without releasing its latch.
        overlay.style = style
    }

    private var speechConfiguration: SpeechConfiguration {
        SpeechConfiguration(languageID: speechLanguageID, mode: speechMode)
    }

    var speechPrivacyDescription: String {
        speechMode == .onDeviceOnly ? "Speech recognition stays on this Mac." : "Speech recognition may send audio to Apple."
    }

    func applySpeechSettings(languageID: String, mode: SpeechRecognitionMode) {
        speechLanguageID = SpeechLanguage.resolve(saved: languageID, preferred: Locale.preferredLanguages,
                                                  available: speechLanguages.map(\.id))
        speechMode = mode
        UserDefaults.standard.set(speechLanguageID, forKey: "speechLanguageID")
        UserDefaults.standard.set(mode.rawValue, forKey: "speechRecognitionMode")
        guard isRunning else {
            speechStatus = "Speech settings saved · start a help session to listen"
            return
        }
        // Only the microphone restarts. Goal, screen generation, and held box
        // belong to the ongoing help session and are left intact.
        speechTask?.cancel()
        let currentSession = sessionID
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.isRunning, self.sessionID == currentSession else { return }
            await self.speech.start(configuration: self.speechConfiguration, preservingTranscript: true)
        }
    }

    func openSpeechPermission() {
        openSystemSettings("com.apple.preference.security?Privacy_SpeechRecognition")
    }

    func openMicrophonePermission() {
        openSystemSettings("com.apple.preference.security?Privacy_Microphone")
    }

    func openDictationSettings() {
        openSystemSettings("com.apple.preference.keyboard")
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    func openScreenPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
