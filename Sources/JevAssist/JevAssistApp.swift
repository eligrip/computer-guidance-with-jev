import AppKit
import SwiftUI
import JevAssistCore

@main
struct JevAssistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            NativeChecks.run()
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let session = SessionController()
    private lazy var setup = SetupCoordinator(languageID: session.speechLanguageID, mode: session.speechMode)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRelauncher.prepareForExit = { [weak self] in self?.session.prepareForAppExit() }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Jev Assist")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.toolTip = "Jev Assist — talk through what you want to do"

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Jev Assist"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.contentView = NSHostingView(rootView: SessionView(session: session, setup: setup, onStart: { [weak self] in
            self?.panel.orderOut(nil)
            self?.session.returnToObservedApp()
            Task {
                await self?.session.start()
                if self?.session.isRunning == false { self?.showPanel() }
            }
        }, onSetupVisibilityChanged: { [weak self] visible in
            // Keep System Settings unobstructed while the user grants access.
            self?.panel.level = visible ? .normal : .floating
        }))
        session.onRunningChanged = { [weak self] active in
            self?.statusItem.button?.image = NSImage(systemSymbolName: active ? "viewfinder.circle.fill" : "viewfinder",
                                                      accessibilityDescription: active ? "Jev Assist listening" : "Jev Assist")
        }
        showPanel()
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); session.returnToObservedApp() }
        else { showPanel() }
    }

    private func showPanel() {
        session.rememberObservedApp()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { session.prepareForAppExit() }
}

private struct SessionView: View {
    @ObservedObject var session: SessionController
    @ObservedObject var setup: SetupCoordinator
    let onStart: () -> Void
    let onSetupVisibilityChanged: (Bool) -> Void
    @State private var draft = ""
    @State private var key = ""
    @State private var showingSettings = false
    @State private var showingSpeechSettings = false
    @State private var showingSetup = UserDefaults.standard.bool(forKey: "setupInProgress")
    @State private var showingHighlightStyles = false
    @State private var showingConversationHistory = false
    @State private var isRestarting = false
    @State private var restartError: String?

    var body: some View {
        Group {
            if showingSetup {
                ScrollView {
                    SetupView(setup: setup, readyActionTitle: session.isRunning ? "Done" : "Start help session",
                              isHelpSessionActive: session.isRunning, onReady: {
                        showingSetup = false
                        if !session.isRunning { onStart() }
                    }, onClose: { showingSetup = false })
                }.frame(width: 440, height: 640)
            } else {
                sessionContent
            }
        }
        .sheet(isPresented: $showingSpeechSettings) { SpeechSettingsView(session: session) }
        .sheet(isPresented: $showingHighlightStyles) { HighlightStylePickerView(session: session) }
        .alert("Couldn’t restart Jev Assist", isPresented: Binding(get: { restartError != nil }, set: { if !$0 { restartError = nil } })) {
            Button("OK") { restartError = nil }
        } message: { Text(restartError ?? "Please try again.") }
        .onChange(of: showingSetup) {
            UserDefaults.standard.set($0, forKey: "setupInProgress")
            onSetupVisibilityChanged($0)
        }
        .onChange(of: session.speechLanguageID) { _ in refreshSetup() }
        .onChange(of: session.speechMode) { _ in refreshSetup() }
        .onAppear {
            refreshSetup()
            onSetupVisibilityChanged(showingSetup)
        }
    }

    private var sessionContent: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.teal.opacity(0.12)).frame(width: 50, height: 50)
                    Image(systemName: "viewfinder").font(.system(size: 27, weight: .medium)).foregroundStyle(.teal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("A little help, right here.").font(.system(size: 21, weight: .semibold))
                    Text("Talk naturally. Follow the highlight.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Circle().fill(session.isRunning ? Color.teal : Color.secondary).frame(width: 7, height: 7)
                Text(session.status).font(.system(size: 12, weight: .medium)).lineLimit(3)
                Spacer()
            }
            .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            if session.isRecording {
                Label("Recording this session on your Mac", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            } else if session.isRunning && session.recordingEnabled && !session.recordingStatus.isEmpty {
                Text(session.recordingStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: startOrSetUp) {
                Label(session.isRunning ? "Stop help session" : "Start help session",
                      systemImage: session.isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(session.isRunning ? .gray : .teal)
            .controlSize(.large)

            if !session.isRunning {
                Text("During a session, the active window, visible Dock, and your words are sent to Jev. \(session.speechPrivacyDescription) You do every click.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("HEARING YOU")
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.conversationFocus.currentRequest.isEmpty ? "Say what you’re trying to do, even if you’re still figuring it out." : session.conversationFocus.currentRequest)
                                .font(.system(size: 14)).foregroundStyle(session.conversationFocus.currentRequest.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Color.clear.frame(height: 1).id("latest-speech")
                        }
                    }
                    .onChange(of: session.conversationFocus.currentRequest) { _ in
                        reader.scrollTo("latest-speech", anchor: .bottom)
                    }
                    .onAppear {
                        reader.scrollTo("latest-speech", anchor: .bottom)
                    }
                }.frame(height: 120)
                if !session.conversationFocus.earlierConversation.isEmpty {
                    DisclosureGroup("Earlier conversation", isExpanded: $showingConversationHistory) {
                        ScrollView {
                            Text(session.conversationFocus.earlierConversation)
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.frame(height: 180)
                    }.font(.system(size: 12))
                }
                Text(session.speechStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("KEEPING IN MIND")
                Text(session.taskAnchor ?? session.goal ?? "Your intention will emerge as you talk.")
                    .font(.system(size: 14)).foregroundStyle(session.taskAnchor == nil && session.goal == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            }

            HStack(spacing: 8) {
                TextField("Or type what’s on your mind…", text: $draft).textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(action: submit) { Image(systemName: "arrow.up") }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add to conversation")
            }

            Divider()
            HStack {
                Button("Your notes") { session.openNotes() }
                Button("Highlight style") { showingHighlightStyles = true }
                Button(isRestarting ? "Restarting…" : "Restart", action: restartApp)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isRestarting)
                    .help("Restart Jev Assist")
                Spacer()
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }.buttonStyle(.plain)
            if !session.metrics.isEmpty {
                Text(session.metrics).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }

            if showingSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Guidance pace", selection: Binding(get: { session.guidancePace }, set: session.setGuidancePace)) {
                        ForEach(GuidancePace.allCases) { pace in Text(pace.title).tag(pace) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Box checks", selection: Binding(get: { session.boxSampling }, set: session.setBoxSampling)) {
                        ForEach(BoxSampling.allCases) { sampling in Text(sampling.title).tag(sampling) }
                    }
                    .pickerStyle(.segmented)
                    Text("Three checks compares three answers before showing a new highlight. Your current highlight stays until the screen changes.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Save session recordings on this Mac", isOn: Binding(get: { session.recordingEnabled }, set: session.setRecordingEnabled))
                        .toggleStyle(.switch).font(.system(size: 13))
                    Text("Saves screen images, your words, and guidance decisions locally. No microphone audio. Old recordings are removed when storage fills.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open recordings") { session.openRecordings() }
                        if !session.recordingStatus.isEmpty {
                            Text(session.recordingStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text(session.hasAPIKey ? "Jev API key is configured" : "Add your Jev API key to begin").font(.caption)
                    HStack {
                        SecureField("New TypeSafe API key", text: $key)
                        Button("Save") { session.saveAPIKey(key); key = "" }.disabled(key.isEmpty)
                    }
                    HStack {
                        Button("Permissions") { refreshSetup(); showingSetup = true }
                        Button("Advanced speech") { showingSpeechSettings = true }
                        Spacer()
                        Button("Quit") { NSApp.terminate(nil) }
                    }.font(.caption)
                }
            }
        }
        .padding(24).frame(width: 440)
        }.frame(width: 440, height: 640)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.addTypedText(text)
        draft = ""
    }

    private func restartApp() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            do { try await AppRelauncher.restart() }
            catch {
                restartError = error.localizedDescription
                isRestarting = false
            }
        }
    }

    private func refreshSetup() {
        setup.configure(languageID: session.speechLanguageID, mode: session.speechMode)
        setup.refresh()
    }

    private func startOrSetUp() {
        if session.isRunning { session.stop(); return }
        refreshSetup()
        if setup.readiness.isReady { onStart() }
        else { showingSetup = true }
    }
}

@MainActor
private struct SpeechSettingsView: View {
    @ObservedObject var session: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var languageID: String
    @State private var mode: SpeechRecognitionMode
    @State private var availability = ""

    init(session: SessionController) {
        self.session = session
        _languageID = State(initialValue: session.speechLanguageID)
        _mode = State(initialValue: session.speechMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speech settings").font(.title2.bold())
            Picker("Spoken language", selection: $languageID) {
                ForEach(session.speechLanguages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .onChange(of: languageID) { _ in checkAvailability() }
            Picker("Recognition", selection: $mode) {
                ForEach(SpeechRecognitionMode.allCases) { option in Text(option.title).tag(option) }
            }
            Text(mode == .onDeviceOnly
                 ? "Audio stays on this Mac. Apple’s on-device speech model must be available for your selected language."
                 : "Apple chooses local or online recognition. Audio may be sent to Apple for transcription. During help sessions, the resulting text is sent to Jev.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(availability).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Check availability again", action: checkAvailability).buttonStyle(.link)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Microphone permission") { session.openMicrophonePermission() }
                Button("Speech permission") { session.openSpeechPermission() }
            }
            Button("Open macOS Dictation settings") { session.openDictationSettings() }
            Text("For local speech, turn on Dictation in macOS Keyboard settings and select the same language. Allow time for Apple’s speech model to download, then check availability again here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Changes apply when you save. If a help session is active, only its microphone restarts; your conversation and guidance continue.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(session.isRunning ? "Apply and retry microphone" : "Save speech settings") {
                    session.applySpeechSettings(languageID: languageID, mode: mode)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear(perform: checkAvailability)
    }

    private func checkAvailability() {
        availability = SpeechConfiguration(languageID: languageID, mode: mode).availabilityDescription()
    }
}
