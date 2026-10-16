import AppKit
import Darwin

/// Restarts the installed bundle through LaunchServices, preserving setup state.
/// The current process exits only after a different instance has launched.
@MainActor
enum AppRelauncher {
    /// The application provides its normal session cleanup explicitly because
    /// restart exits directly after handoff, bypassing SwiftUI's sheet veto.
    static var prepareForExit: (() -> Void)?

    enum Failure: LocalizedError {
        case notBundled, couldNotOpen
        var errorDescription: String? {
            switch self {
            case .notBundled: return "Open Jev Assist from its app icon, then try restarting again."
            case .couldNotOpen: return "Jev Assist couldn’t reopen. You can quit it and open its app icon again."
            }
        }
    }

    /// Changes when a newly built executable replaces the bundle on disk. This
    /// bounds restart recovery per build without depending on a static version.
    static var buildToken: String {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return Bundle.main.bundleURL.path
        }
        return "\(executable.path):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }

    static func restart(showSetup: Bool = false) async throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw Failure.notBundled }
        guard let prepareForExit else { throw Failure.couldNotOpen }
        // Normal restarts return to the session panel. Only permission recovery
        // explicitly asks to reopen setup; a failed launch restores prior state.
        let previousSetup = UserDefaults.standard.object(forKey: "setupInProgress")
        UserDefaults.standard.set(showSetup, forKey: "setupInProgress")
        UserDefaults.standard.synchronize()
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = true
        options.activates = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--project-root"), index + 1 < arguments.count {
            options.arguments = ["--project-root", arguments[index + 1]]
        }
        do {
            let restarted: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: bundle, configuration: options) { app, error in
                    if let app, error == nil { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: Failure.couldNotOpen) }
                }
            }
            guard restarted.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !restarted.isTerminated else { throw Failure.couldNotOpen }
        } catch {
            if let previousSetup { UserDefaults.standard.set(previousSetup, forKey: "setupInProgress") }
            else { UserDefaults.standard.removeObject(forKey: "setupInProgress") }
            UserDefaults.standard.synchronize()
            throw error
        }

        // This utility has no unsaved documents. Once the replacement is live,
        // stop microphone/capture/inference and exit our own process directly;
        // NSApplication.terminate can be vetoed by the open SwiftUI setup sheet.
        prepareForExit()
        UserDefaults.standard.set(showSetup, forKey: "setupInProgress")
        UserDefaults.standard.synchronize()
        Darwin.exit(EXIT_SUCCESS)
    }
}
