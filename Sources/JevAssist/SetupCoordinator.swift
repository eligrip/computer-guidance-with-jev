import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum SetupStep: String, CaseIterable, Identifiable {
    case screen, accessibility, voice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: return "Screen access"
        case .accessibility: return "Accessibility"
        case .voice: return "Voice"
        }
    }
    var symbol: String {
        switch self {
        case .screen: return "display"
        case .accessibility: return "hand.point.up.left"
        case .voice: return "mic"
        }
    }
}

enum SetupPermission: Equatable { case notRequested, allowed, denied, restricted }
enum VoiceSetupAction: Equatable { case requestPermission, microphoneSettings, speechSettings, dictationSettings, checkAgain, restricted }

/// Pure readiness policy, independently testable without requesting permission,
/// recording audio, or inspecting a user's screen.
struct SetupReadiness: Equatable {
    var screen = false
    var accessibility = false
    var microphone = SetupPermission.notRequested
    var speech = SetupPermission.notRequested
    var recognizerExists = false
    var localModel = false
    var speechService = false
    var requiresLocalModel = true

    var voiceReady: Bool {
        microphone == .allowed && speech == .allowed && recognizerExists && speechService &&
            (!requiresLocalModel || localModel)
    }
    var isReady: Bool { screen && accessibility && voiceReady }
    var nextStep: SetupStep? { SetupStep.allCases.first { !isComplete($0) } }
    func isComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .screen: return screen
        case .accessibility: return accessibility
        case .voice: return voiceReady
        }
    }
    var voiceAction: VoiceSetupAction {
        if microphone == .restricted || speech == .restricted { return .restricted }
        if microphone == .denied { return .microphoneSettings }
        if speech == .denied { return .speechSettings }
        if microphone == .notRequested || speech == .notRequested { return .requestPermission }
        if requiresLocalModel && (!recognizerExists || !localModel) { return .dictationSettings }
        return .checkAgain
    }
}

@MainActor
final class SetupCoordinator: ObservableObject {
    @Published private(set) var readiness = SetupReadiness()
    @Published private(set) var isRequesting = false
    @Published private(set) var notice: String?
    private var configuration: SpeechConfiguration
    private var recognizer: SFSpeechRecognizer?
    private var requestTask: Task<Void, Never>?
    private var requestGeneration = UUID()
    private var requestedScreen: Bool
    private var requestedAccessibility: Bool

    init(languageID: String, mode: SpeechRecognitionMode) {
        configuration = SpeechConfiguration(languageID: languageID, mode: mode)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID))
        requestedScreen = UserDefaults.standard.bool(forKey: "setupRequestedScreen")
        requestedAccessibility = UserDefaults.standard.bool(forKey: "setupRequestedAccessibility")
        // No permission prompts or recording happen during initialization.
    }

    func configure(languageID: String, mode: SpeechRecognitionMode) {
        if configuration.languageID != languageID {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID))
        }
        configuration = SpeechConfiguration(languageID: languageID, mode: mode)
    }

    func refresh() {
        let oldStep = readiness.nextStep
        var next = SetupReadiness()
        next.screen = CGPreflightScreenCaptureAccess()
        next.accessibility = AXIsProcessTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: next.microphone = .allowed
        case .denied: next.microphone = .denied
        case .restricted: next.microphone = .restricted
        case .notDetermined: next.microphone = .notRequested
        @unknown default: next.microphone = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: next.speech = .allowed
        case .denied: next.speech = .denied
        case .restricted: next.speech = .restricted
        case .notDetermined: next.speech = .notRequested
        @unknown default: next.speech = .denied
        }
        next.recognizerExists = recognizer != nil
        next.localModel = recognizer?.supportsOnDeviceRecognition ?? false
        next.speechService = recognizer?.isAvailable ?? false
        next.requiresLocalModel = configuration.requiresOnDeviceRecognition
        readiness = next
        if next.nextStep != oldStep { notice = nil }
    }

    var explanation: String {
        switch readiness.nextStep {
        case .screen:
            return requestedScreen
                ? "Turn on Jev Assist in Screen Recording. If your Mac asks, choose Quit & Reopen."
                : "Let Jev Assist see the window you’re using and your Dock so it can show you where to click."
        case .accessibility:
            return requestedAccessibility
                ? "Turn on Jev Assist in Accessibility. Then return here; we’ll check it for you."
                : "Let Jev Assist recognize buttons and controls. You still do every click."
        case .voice:
            switch readiness.voiceAction {
            case .requestPermission:
                return "Allow the microphone and speech recognition when your Mac asks. We’ll guide you through both."
            case .microphoneSettings:
                return "Turn on Jev Assist in Microphone. Then return here."
            case .speechSettings:
                return "Turn on Jev Assist in Speech Recognition. Then return here."
            case .dictationSettings:
                return "Turn on Dictation in Keyboard settings and choose \(configuration.languageName). Your Mac may need a moment to download its voice files."
            case .restricted:
                return "Voice access is restricted by this Mac’s settings. The person who manages this Mac can enable microphone and speech access."
            case .checkAgain:
                return "Your Mac’s voice service isn’t ready yet. We’ll keep checking while this window is open."
            }
        case nil:
            return "You’re ready. Start a help session, then talk through what you want to do."
        }
    }

    var actionTitle: String {
        switch readiness.nextStep {
        case .screen: return requestedScreen ? "Open Screen Recording" : "Allow screen access"
        case .accessibility: return requestedAccessibility ? "Open Accessibility" : "Allow Accessibility"
        case .voice:
            switch readiness.voiceAction {
            case .requestPermission: return "Allow voice"
            case .microphoneSettings, .speechSettings: return "Open voice access"
            case .dictationSettings: return "Set up voice"
            case .checkAgain, .restricted: return "Check again"
            }
        case nil: return "Start help session"
        }
    }

    func performPrimaryAction() {
        guard !isRequesting else { return }
        let displayedStep = readiness.nextStep
        refresh()
        // A grant may have arrived since the button was drawn. Show the next
        // step first; a click for Screen access must not request Voice or AX.
        guard readiness.nextStep == displayedStep else { return }
        notice = nil
        switch readiness.nextStep {
        case .screen:
            if requestedScreen { openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
            else {
                requestedScreen = true
                UserDefaults.standard.set(true, forKey: "setupRequestedScreen")
                _ = CGRequestScreenCaptureAccess()
                refresh()
            }
        case .accessibility:
            if requestedAccessibility { openSettings("com.apple.preference.security?Privacy_Accessibility") }
            else {
                requestedAccessibility = true
                UserDefaults.standard.set(true, forKey: "setupRequestedAccessibility")
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                refresh()
            }
        case .voice:
            switch readiness.voiceAction {
            case .requestPermission: requestVoicePermissions()
            case .microphoneSettings: openSettings("com.apple.preference.security?Privacy_Microphone")
            case .speechSettings: openSettings("com.apple.preference.security?Privacy_SpeechRecognition")
            case .dictationSettings: openSettings("com.apple.preference.keyboard")
            case .checkAgain, .restricted: refresh()
            }
        case nil: break
        }
    }

    func cancelPendingAction() {
        requestGeneration = UUID()
        requestTask?.cancel()
        requestTask = nil
        isRequesting = false
    }

    private func requestVoicePermissions() {
        isRequesting = true
        let generation = UUID()
        requestGeneration = generation
        requestTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.requestGeneration == generation else { return }
            defer {
                if self.requestGeneration == generation {
                    self.isRequesting = false
                    self.requestTask = nil
                    self.refresh()
                }
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard !Task.isCancelled, self.requestGeneration == generation,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
        }
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)"), NSWorkspace.shared.open(url) else {
            notice = "Open System Settings from the Apple menu to continue this step."
            return
        }
    }
}
