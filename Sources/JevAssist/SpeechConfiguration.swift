import Foundation
import Speech

enum SpeechRecognitionMode: String, CaseIterable, Identifiable {
    case onDeviceOnly
    case appleAutomatic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDeviceOnly: return "On-device only"
        case .appleAutomatic: return "Allow Apple online recognition"
        }
    }

    /// Online recognition always requires the user's explicit saved choice.
    static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .onDeviceOnly
    }
}

struct SpeechLanguage: Identifiable {
    let id: String
    let name: String

    static func name(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static var available: [Self] {
        Set(SFSpeechRecognizer.supportedLocales().map { canonical($0.identifier) })
            .map { Self(id: $0, name: name(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func canonical(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    static func resolve(saved: String?, preferred: [String], available: [String]) -> String {
        let supported = available.map(canonical).sorted()
        if let saved, let match = supported.first(where: { $0.caseInsensitiveCompare(canonical(saved)) == .orderedSame }) {
            return match
        }
        for preference in preferred {
            let requested = canonical(preference)
            if let exact = supported.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) { return exact }
            let language = Locale(identifier: requested)
            if let related = supported.first(where: {
                let candidate = Locale(identifier: $0)
                return candidate.language.languageCode == language.language.languageCode &&
                    (language.language.script == nil || candidate.language.script == language.language.script)
            }) { return related }
        }
        return supported.first(where: { $0 == "en-US" }) ?? supported.first ?? "en-US"
    }
}

struct SpeechConfiguration {
    let languageID: String
    let mode: SpeechRecognitionMode

    var languageName: String { SpeechLanguage.name(for: languageID) }
    var requiresOnDeviceRecognition: Bool { mode == .onDeviceOnly }

    func blocker(recognizerExists: Bool, onDeviceSupported: Bool, serviceAvailable: Bool) -> String? {
        guard recognizerExists else { return "Apple speech doesn’t support \(languageName). Choose another language in Speech settings." }
        if requiresOnDeviceRecognition && !onDeviceSupported {
            return "Apple’s on-device model for \(languageName) is not available yet. Open Speech settings to set up macOS Dictation for this language, then retry."
        }
        if !serviceAvailable {
            return "Apple speech for \(languageName) is temporarily unavailable. Check your connection and Speech settings, then retry."
        }
        return nil
    }

    func availabilityDescription() -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)) else {
            return "Apple speech doesn’t support \(languageName)."
        }
        let local = recognizer.supportsOnDeviceRecognition ? "On-device recognition is available." : "The on-device speech model is not available to this app."
        let service = recognizer.isAvailable ? "Apple’s recognition service is available." : "Apple’s recognition service is currently unavailable."
        return "\(languageName): \(local) \(service)"
    }
}
