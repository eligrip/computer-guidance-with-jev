import AppKit
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        panel.contentView = NSHostingView(rootView: SessionView(session: session, onStart: { [weak self] in
            self?.panel.orderOut(nil)
            self?.session.returnToObservedApp()
            Task {
                await self?.session.start()
                if self?.session.isRunning == false { self?.showPanel() }
            }
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

    func applicationWillTerminate(_ notification: Notification) { session.stop() }
}

private struct SessionView: View {
    @ObservedObject var session: SessionController
    let onStart: () -> Void
    @State private var draft = ""
    @State private var key = ""
    @State private var showingSettings = false

    var body: some View {
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

            Button(action: { session.isRunning ? session.stop() : onStart() }) {
                Label(session.isRunning ? "Stop help session" : "Start help session",
                      systemImage: session.isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(session.isRunning ? .gray : .teal)
            .controlSize(.large)

            if !session.isRunning {
                Text("During a session, the active window and your words are sent to Jev. Speech recognition stays on this Mac. You do every click.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("HEARING YOU")
                ScrollView {
                    Text(session.transcript.isEmpty ? "Say what you’re trying to do, even if you’re still figuring it out." : session.transcript)
                        .font(.system(size: 14)).foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 85)
                Text(session.speechStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("KEEPING IN MIND")
                Text(session.goal ?? "Your intention will emerge as you talk.")
                    .font(.system(size: 14)).foregroundStyle(session.goal == nil ? .secondary : .primary)
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
                Spacer()
                Text(session.metrics).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }.buttonStyle(.plain)

            if showingSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.hasAPIKey ? "Jev API key is configured" : "Add your Jev API key to begin").font(.caption)
                    HStack {
                        SecureField("New TypeSafe API key", text: $key)
                        Button("Save") { session.saveAPIKey(key); key = "" }.disabled(key.isEmpty)
                    }
                    HStack {
                        Button("Screen access") { session.openScreenPermission() }
                        Button("Accessibility") { session.requestAccessibility() }
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
}
