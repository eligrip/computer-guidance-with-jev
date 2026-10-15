import Foundation
import Darwin

// Chrome native messaging owns stdin/stdout. Never log page content or ordinary
// text to stdout: every reply must be a little-endian length-prefixed JSON frame.
let maximumMessageBytes = 240 * 1024
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let fileManager = FileManager.default
let connectionID = UUID().uuidString
let supportURL: URL = {
    if let override = ProcessInfo.processInfo.environment["JEV_ASSIST_SUPPORT_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JevAssist", isDirectory: true)
}()
let contextURL = supportURL.appendingPathComponent("browser-context.json")
umask(0o077)

struct Header: Decodable { let type: String }
struct Rect: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
struct Control: Codable {
    let id: String
    let tag: String
    let role: String
    let label: String
    let href: String?
    let rect: Rect
    let visible: Bool
    let inViewport: Bool
    let disabled: Bool
}
struct Page: Codable {
    let url: String
    let title: String
    let scope: String
    let untrusted: Bool
    let loadedText: String
    let textTruncated: Bool
    let controls: [Control]
    let controlsTruncated: Bool
    let limitations: String
}
struct Viewport: Codable {
    let width: Double
    let height: Double
    let scrollX: Double
    let scrollY: Double
    let devicePixelRatio: Double
}
struct Context: Codable {
    let schemaVersion: Int
    let sharing: Bool
    let capturedAt: String
    let browser: String
    let browserBundleID: String
    let sessionID: String
    let sequence: Int
    let tabID: Int
    let windowID: Int
    let page: Page
    let viewport: Viewport
    let reason: String
    var receivedAt: String?
    var bridgeConnectionID: String?
}
enum BridgeError: Error { case truncatedFrame, invalidLength, invalidContext }

func readExactly(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else {
            if data.isEmpty { return nil }
            throw BridgeError.truncatedFrame
        }
        data.append(chunk)
    }
    return data
}

func readFrame() throws -> Data? {
    guard let header = try readExactly(4) else { return nil }
    let bytes = [UInt8](header)
    let length = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    guard length > 0, length <= maximumMessageBytes else { throw BridgeError.invalidLength }
    guard let body = try readExactly(length) else { throw BridgeError.truncatedFrame }
    return body
}

func reply(ok: Bool, error: String? = nil) throws {
    var body: [String: Any] = ["ok": ok, "schemaVersion": 1]
    if let error { body["error"] = error }
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let length = UInt32(data.count)
    let prefix = Data([UInt8(length & 255), UInt8((length >> 8) & 255), UInt8((length >> 16) & 255), UInt8((length >> 24) & 255)])
    try output.write(contentsOf: prefix + data)
}

func clearOwnedContext() {
    // Another Chrome profile may have a live bridge. Do not remove its newer file.
    guard let data = try? Data(contentsOf: contextURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["bridgeConnectionID"] as? String == connectionID else { return }
    try? fileManager.removeItem(at: contextURL)
}

func dateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

func validURL(_ value: String) -> Bool {
    guard value.utf8.count <= 16_384, let url = URLComponents(string: value),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
    return true
}

func bounded(_ number: Double, _ maximum: Double = 1_000_000) -> Bool {
    number.isFinite && abs(number) <= maximum
}

func validate(_ context: Context) throws {
    guard context.schemaVersion == 1, context.sharing,
          context.browser == "chrome", context.browserBundleID == "com.google.Chrome",
          UUID(uuidString: context.sessionID) != nil,
          context.sequence > 0, context.tabID >= 0, context.windowID >= 0,
          context.reason.count <= 80,
          let captured = dateFormatter().date(from: context.capturedAt),
          abs(captured.timeIntervalSinceNow) <= 10,
          validURL(context.page.url), context.page.title.count <= 500,
          context.page.scope == "loaded-top-frame", context.page.untrusted,
          context.page.loadedText.count <= 24_000, context.page.controls.count <= 180,
          context.page.limitations.count <= 1000,
          context.viewport.width > 0, context.viewport.height > 0,
          bounded(context.viewport.width, 100_000), bounded(context.viewport.height, 100_000),
          bounded(context.viewport.scrollX), bounded(context.viewport.scrollY),
          context.viewport.devicePixelRatio > 0, bounded(context.viewport.devicePixelRatio, 16)
    else { throw BridgeError.invalidContext }
    for control in context.page.controls {
        guard control.id.count <= 80, control.tag.count <= 40, control.role.count <= 40,
              control.label.count <= 240, control.href.map(validURL) ?? true,
              bounded(control.rect.x), bounded(control.rect.y),
              bounded(control.rect.width), bounded(control.rect.height),
              control.rect.width >= 0, control.rect.height >= 0 else { throw BridgeError.invalidContext }
    }
}

func save(_ incoming: Context) throws {
    try validate(incoming)
    var context = incoming
    context.receivedAt = dateFormatter().string(from: Date())
    context.bridgeConnectionID = connectionID
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(context)
    guard data.count <= maximumMessageBytes else { throw BridgeError.invalidLength }
    try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // umask protects the temporary file before the atomic rename, too.
    try data.write(to: contextURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)
}

func run() {
    defer { clearOwnedContext() }
    while true {
        do {
            guard let data = try readFrame() else { return }
            do {
                let header = try JSONDecoder().decode(Header.self, from: data)
                switch header.type {
                case "context":
                    let context = try JSONDecoder().decode(Context.self, from: data)
                    try save(context)
                    try reply(ok: true)
                case "clear":
                    clearOwnedContext()
                    try reply(ok: true)
                case "stop":
                    clearOwnedContext()
                    try reply(ok: true)
                    return
                default:
                    clearOwnedContext()
                    try reply(ok: false, error: "unsupported_message")
                }
            } catch {
                clearOwnedContext()
                try reply(ok: false, error: "invalid_context")
            }
        } catch {
            // A malformed/truncated frame cannot be resynchronized safely.
            try? reply(ok: false, error: "invalid_frame")
            return
        }
    }
}

run()
