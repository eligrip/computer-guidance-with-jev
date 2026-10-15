import AppKit
import Security

enum LocalStorage {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JevAssist", isDirectory: true)
    static let notesURL = directory.appendingPathComponent("user_notes.md")
    private static let keyService = "ai.typesafe.jevassist"

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: notesURL.path) {
            let initial = (Bundle.main.url(forResource: "user_notes.example", withExtension: "md")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? """
            # My notes

            Add things you want Jev to remember: your preferred apps, recurring tasks,
            or what you mean when you say things like “my email.”

            These notes are included with Jev requests during help sessions.
            Edit this file whenever your preferences change.

            """
            try? initial.write(to: notesURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notesURL.path)
        }
    }

    static func readNotes() -> String {
        String((try? String(contentsOf: notesURL, encoding: .utf8))?.prefix(8_000) ?? "")
    }

    static func loadKey() -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keyService,
                                   kSecAttrAccount as String: "TYPESAFE_API_KEY"]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }
        if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty { return key }
        let arguments = ProcessInfo.processInfo.arguments
        let rootArgument = arguments.firstIndex(of: "--project-root").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        let adjacentRoot = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let bundledRoot = FileManager.default.fileExists(atPath: adjacentRoot.appendingPathComponent(".env.local").path) ? adjacentRoot.path : nil
        let root = rootArgument ?? ProcessInfo.processInfo.environment["JEV_ASSIST_PROJECT_ROOT"] ?? bundledRoot ?? FileManager.default.currentDirectoryPath
        let file = URL(fileURLWithPath: root).appendingPathComponent(".env.local")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TYPESAFE_API_KEY=") else { continue }
            var value = String(trimmed.dropFirst("TYPESAFE_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func saveKey(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keyService,
                                   kSecAttrAccount as String: "TYPESAFE_API_KEY"]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func browserContext(for bundleID: String?) -> String? {
        guard let bundleID, bundleID == "com.google.Chrome",
              let data = try? Data(contentsOf: directory.appendingPathComponent("browser-context.json")), data.count < 300_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1, json["sharing"] as? Bool == true,
              json["browserBundleID"] as? String == bundleID,
              let timestamp = json["receivedAt"] as? String,
              let page = json["page"] as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp), Date().timeIntervalSince(date) >= -1,
              Date().timeIntervalSince(date) <= 3 else { return nil }
        guard let scoped = try? JSONSerialization.data(withJSONObject: ["page": page, "viewport": json["viewport"] ?? [:]]) else { return nil }
        return String(data: scoped, encoding: .utf8)
    }
}
