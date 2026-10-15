import AppKit
import Foundation

/// Opt-in transport smoke test. The only uploaded image is drawn below; this
/// program never captures the display, opens the microphone, or reads user notes.
@main
@MainActor
enum NativeJevSmoke {
    struct SmokeFailure: Error { let message: String }

    static func main() async {
        guard CommandLine.arguments.contains("--live") else {
            print("Opt-in required: bash scripts/smoke-native.sh --live")
            print("This makes two Jev requests using a generated image and synthetic speech.")
            exit(2)
        }
        do {
            let key = try loadKey()
            let image = try makeFixture()
            let client = JevClient(apiKey: key)
            let transcript = "Sarah sent me this photo. I want to save this photo to my computer."

            let goalStart = Date()
            let goal = try await client.inferGoal(transcript: transcript, previousGoal: nil)
            let goalMilliseconds = Int(Date().timeIntervalSince(goalStart) * 1_000)
            guard let goal, transcript.contains(goal) else {
                throw SmokeFailure(message: "Goal response did not select an exact span of synthetic speech.")
            }

            let input = GuidanceInput(transcript: transcript, goal: goal, notes: "",
                                      browserContext: "Synthetic photo attachment page; one visible Save photo button.",
                                      accessibilityContext: nil, imageJPEG: image)
            let guidanceStart = Date()
            let result = try await client.guidance(input)
            let guidanceMilliseconds = Int(Date().timeIntervalSince(guidanceStart) * 1_000)
            guard let box = result.box else {
                throw SmokeFailure(message: "Guidance returned no supported box for the synthetic Save photo button.")
            }
            let centerX = (box.left + box.right) / 2
            let centerY = (box.top + box.bottom) / 2
            // Fixture button: x=250...750, y=90...200 in AppKit's bottom-left
            // 1000×650 coordinate space. Jev uses top-left normalized coordinates.
            let centerInsideButton = (0.25...0.75).contains(centerX)
                && ((450.0 / 650.0)...(560.0 / 650.0)).contains(centerY)
            let report: [String: Any] = [
                "model": client.model,
                "fixture_only": true,
                "request_count": 2,
                "image_transport": "multipart/form-data",
                "fixture_pixels": [1000, 650],
                "fixture_jpeg_bytes": image.count,
                "goal_is_exact_source_span": true,
                "selected_goal": goal,
                "goal_latency_ms": goalMilliseconds,
                "guidance_latency_ms": guidanceMilliseconds,
                "presence": result.presence,
                "confidence": result.confidence,
                "box": ["top": box.top, "bottom": box.bottom, "left": box.left, "right": box.right],
                "box_center_inside_expected_button": centerInsideButton
            ]
            let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: output, as: UTF8.self))
            guard centerInsideButton else {
                throw SmokeFailure(message: "Transport succeeded, but the returned box did not center on the expected button.")
            }
            print("PASS: native JevClient goal selection and multipart Box guidance.")
        } catch let error as SmokeFailure {
            fputs("Native smoke failed: \(error.message)\n", stderr)
            exit(1)
        } catch let error as JevError {
            // JevError contains safe status text, never request or error bodies.
            fputs("Native smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        } catch let error as URLError {
            fputs("Native smoke network failure (URL error \(error.code.rawValue)).\n", stderr)
            exit(1)
        } catch {
            fputs("Native smoke failed while preparing or decoding the synthetic fixture.\n", stderr)
            exit(1)
        }
    }

    private static func loadKey() throws -> String {
        if let value = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !value.isEmpty {
            return value
        }
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env.local")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            throw SmokeFailure(message: "Set TYPESAFE_API_KEY or use the project's local key setup helper.")
        }
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "TYPESAFE_API_KEY" else { continue }
            var key = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key.count >= 2, (key.first == "\"" && key.last == "\"" || key.first == "'" && key.last == "'") {
                key.removeFirst()
                key.removeLast()
            }
            guard !key.isEmpty else { continue }
            return key
        }
        throw SmokeFailure(message: "The local environment file does not contain a TypeSafe key.")
    }

    private static func makeFixture() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_000, pixelsHigh: 650,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SmokeFailure(message: "Could not create the synthetic image canvas.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1_000, height: 650).fill()
        let title = "A photo from Sarah" as NSString
        title.draw(at: NSPoint(x: 80, y: 560), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.black
        ])
        NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 250, y: 260, width: 500, height: 230), xRadius: 16, yRadius: 16).fill()
        NSColor(calibratedRed: 0.35, green: 0.66, blue: 0.48, alpha: 1).setFill()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 260, y: 275))
        mountain.line(to: NSPoint(x: 440, y: 440))
        mountain.line(to: NSPoint(x: 620, y: 275))
        mountain.close()
        mountain.fill()
        NSColor(calibratedRed: 0.97, green: 0.79, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 620, y: 390, width: 60, height: 60)).fill()
        let button = NSRect(x: 250, y: 90, width: 500, height: 110)
        NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(roundedRect: button, xRadius: 16, yRadius: 16).fill()
        let label = "Save photo" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2),
                   withAttributes: attributes)
        context.flushGraphics()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw SmokeFailure(message: "Could not encode the synthetic JPEG.")
        }
        return jpeg
    }
}
